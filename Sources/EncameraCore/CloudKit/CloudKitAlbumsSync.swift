//
//  CloudKitAlbumsSync.swift
//  EncameraCore
//
//  App-level sync for CloudKit pushes: observes `cloudKitZoneChanged` and runs one
//  pass over the zone for every CloudKit album, the open one and the rest alike.
//  A pass is one walk of the zone change feed by the shared
//  `CloudKitSyncCoordinator`, with the album reconcile run between the walk and
//  the media changes it routes.
//
//  Every pass ends with a walk of the iCloud Drive album folders
//  (`ICloudDriveAlbumFolderWalk`), which also runs whenever an album folder's
//  marker file appears, changes or finishes downloading
//  (`ICloudDriveAlbumMarkerMonitor`).
//
//  The sync never runs the iCloud Drive album migration
//  (`ICloudDriveAlbumMigration`): only a user's start does.
//
//  The walk itself is not held for Wi-Fi. On a device that has the folder, album
//  sync adopts the `EncAlbum` on its own and the album list then hides the
//  folder, so skipping the walk would not show the album twice; but the walk is
//  what links the adopted album to its folder, so skipping it would hide every
//  item still on iCloud Drive until Wi-Fi returned. Linking is local, and the
//  walk's own CloudKit requests already wait for Wi-Fi (`makeMigrationStore`).
//

import Foundation

public actor CloudKitAlbumsSync: DebugPrintable {

    private let albumManager: AlbumManaging
    private let makeReconciler: @Sendable (AlbumManaging) -> CloudKitAlbumReconciler
    private let makeCoordinator: @Sendable (AlbumManaging) -> CloudKitSyncCoordinator
    private let makeFolderWalk: @Sendable (AlbumManaging) -> ICloudDriveAlbumFolderWalk
    private let markerMonitor: ICloudDriveAlbumMarkerMonitor?
    /// Gates reconciliation on the launch-time credential wait having resolved.
    /// `CloudKitAlbumReconciler` matches synced keys against a one-way album-id
    /// hash, so running it while iCloud Keychain credentials are still in flight
    /// reports every remote album as "needs a key" and shows an empty grid. The
    /// key can appear mid-wait (`.restoringKeyMaterial` re-derives it), which
    /// fires `keyPublisher` and would otherwise start a sync early.
    private let isReadyToSync: @Sendable () -> Bool
    /// Nil means `CloudKitSyncStatusReporter.shared`, which can only be read on
    /// the main actor.
    private let statusReporter: CloudKitSyncStatusReporter?
    private var observer: NSObjectProtocol?
    private var keyLibraryObserver: NSObjectProtocol?

    /// The most recent count of remote albums that could not be materialized for lack
    /// of a synced key (key backup off). The UI reads this to prompt "N albums need
    /// key backup to appear here".
    public private(set) var albumsNeedingPrivateKey: Int = 0

    private var activeSync: Task<Void, Never>?
    private(set) var resyncRequested = false
    private var activeFolderWalk: Task<Void, Never>?
    private var folderWalkRequested = false

    public init(albumManager: AlbumManaging,
                observeNotifications: Bool = true,
                isReadyToSync: @escaping @Sendable () -> Bool = { true },
                statusReporter: CloudKitSyncStatusReporter? = nil,
                makeReconciler: (@Sendable (AlbumManaging) -> CloudKitAlbumReconciler)? = nil,
                makeCoordinator: (@Sendable (AlbumManaging) -> CloudKitSyncCoordinator)? = nil,
                makeFolderWalk: (@Sendable (AlbumManaging) -> ICloudDriveAlbumFolderWalk)? = nil) {
        self.albumManager = albumManager
        self.isReadyToSync = isReadyToSync
        self.statusReporter = statusReporter
        self.makeReconciler = makeReconciler ?? { albumManager in
            CloudKitAlbumReconciler(store: CloudKitStoreProvider.makeStore(""),
                                    keyManager: albumManager.keyManager,
                                    albumManager: albumManager)
        }
        self.makeCoordinator = makeCoordinator ?? { CloudKitSyncCoordinator.shared(albumManager: $0) }
        self.makeFolderWalk = makeFolderWalk ?? { albumManager in
            ICloudDriveAlbumFolderWalk(albumManager: albumManager,
                                       makeStore: { CloudKitStoreProvider.makeMigrationStore("iCloudDriveAlbumFolderWalk") })
        }
        let markerMonitor = observeNotifications ? ICloudDriveAlbumMarkerMonitor() : nil
        self.markerMonitor = markerMonitor
        if observeNotifications {
            observer = NotificationCenter.default.addObserver(
                forName: .cloudKitZoneChanged, object: nil, queue: nil
            ) { [weak self] _ in
                Self.printDebug("cloudKitZoneChanged received; scheduling syncAll")
                Task { await self?.syncAll() }
            }
            keyLibraryObserver = NotificationCenter.default.addObserver(
                forName: .keyLibraryDidGrow, object: nil, queue: nil
            ) { [weak self] _ in
                Self.printDebug("keyLibraryDidGrow received; scheduling syncAll")
                Task { await self?.syncAll() }
            }
        }
        if let markerMonitor {
            markerMonitor.onChange = { [weak self] in
                Task(priority: .utility) {
                    await self?.walkICloudDriveAlbumFolders()
                }
            }
            Task { @MainActor in markerMonitor.start() }
        }
    }

    private func reporter() async -> CloudKitSyncStatusReporter {
        if let statusReporter { return statusReporter }
        return await CloudKitSyncStatusReporter.shared
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let keyLibraryObserver { NotificationCenter.default.removeObserver(keyLibraryObserver) }
    }

    /// Walks the zone once, reconciles album *existence* from what the walk and the
    /// album query say (materialize newly-discovered albums, remove ones deleted
    /// elsewhere, push local-only ones up), THEN applies the walk's media changes to
    /// every CloudKit album's index — so a newly materialized album gets its media
    /// from the same walk. Local/iCloud-Drive albums are ignored throughout.
    /// Overlapping calls coalesce into the in-flight run.
    public func syncAll() async {
        if let active = activeSync {
            resyncRequested = true
            printDebug("syncAll join reason=syncInFlight resyncRequested=true")
            await active.value
            printDebug("syncAll join done")
            return
        }
        printDebug("syncAll start")
        let task = Task {
            defer { activeSync = nil }
            await drainSyncAll()
        }
        activeSync = task
        await task.value
        printDebug("syncAll ok")
    }

    private func drainSyncAll() async {
        var pass = 0
        repeat {
            resyncRequested = false
            pass += 1
            printDebug("drainSyncAll pass=\(pass)")
            await performSyncAll()
        } while resyncRequested
        printDebug("drainSyncAll ok passes=\(pass)")
    }

    /// Walks the iCloud Drive album folders once (see `ICloudDriveAlbumFolderWalk`).
    /// A call during a walk joins it and has it walk again when it finishes.
    public func walkICloudDriveAlbumFolders() async {
        if let active = activeFolderWalk {
            folderWalkRequested = true
            await active.value
            return
        }
        let task = Task {
            defer { activeFolderWalk = nil }
            repeat {
                folderWalkRequested = false
                await makeFolderWalk(albumManager).run()
            } while folderWalkRequested
        }
        activeFolderWalk = task
        await task.value
    }

    private func performSyncAll() async {
        guard isReadyToSync() else {
            printDebug("performSyncAll skip reason=awaitingCredentialRestore")
            return
        }
        await performCloudKitPass()
        await walkICloudDriveAlbumFolders()
    }

    private func performCloudKitPass() async {

        let hasCloudKitAlbums = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .contains { $0.storageOption == .cloudKit }
        printDebug("performSyncAll start hasCloudKitAlbums=\(hasCloudKitAlbums)")

        // The reconcile still runs without a local CloudKit album (it adopts
        // albums other devices created), but only a check against an available
        // account on behalf of a CloudKit album is reported. Otherwise the bar
        // would tell local-only and signed-out users that iCloud is up to date.
        let reconciler = makeReconciler(albumManager)
        let reportsCheck = hasCloudKitAlbums ? await reconciler.accountAvailable() : false
        if reportsCheck {
            await reporter().reportCheckStarted()
        } else {
            printDebug("performSyncAll status unreported reason=\(hasCloudKitAlbums ? "accountUnavailable" : "noCloudKitAlbums")")
        }

        let reconciled = ReconcileOutcome()
        if await reconciler.accountAvailable() {
            do {
                try await makeCoordinator(albumManager).sync(albumPass: { changes in
                    await reconciled.set(await reconciler.reconcileAlbums(changes: changes))
                })
            } catch {
                printDebug("performSyncAll zoneSync FAILED raw=\(error)")
            }
        }
        // A walk that failed before the album pass still reconciles what the album
        // query can say, as the reconcile did when it read the feed itself.
        let result: CloudKitAlbumReconcileResult
        if let fromWalk = await reconciled.result {
            result = fromWalk
        } else {
            result = await reconciler.reconcileAlbums(changes: .none)
        }
        albumsNeedingPrivateKey = result.lockedOutCount
        printDebug("performSyncAll reconcileAlbums done result=\(result)")
        await LockedAlbumsReporter.shared.report(lockedAlbumCount: albumsNeedingPrivateKey)

        let albumCount = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .filter { $0.storageOption == .cloudKit }.count
        await CloudKitUploader.shared.kick()
        if reportsCheck {
            await reporter().reportCheckFinished(succeeded: result.succeeded, storageFull: result.storageFull)
        }
        printDebug("performSyncAll ok albumCount=\(albumCount) albumsNeedingKey=\(albumsNeedingPrivateKey)")
    }
}

/// The album pass's result, carried out of the coordinator's sync.
private actor ReconcileOutcome {
    private(set) var result: CloudKitAlbumReconcileResult?

    func set(_ result: CloudKitAlbumReconcileResult) {
        self.result = result
    }
}
