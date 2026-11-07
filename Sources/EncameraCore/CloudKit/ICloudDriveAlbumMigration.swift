//
//  ICloudDriveAlbumMigration.swift
//  EncameraCore
//
//  Gives an iCloud Drive album its CloudKit album without moving any media: the
//  album's media stays in its iCloud Drive folder and moves later, item by item.
//
//  For one album folder:
//
//  1. Read the folder's marker file (`ICloudDriveAlbumMarkerFile`). One that names
//     an album makes that album the folder's CloudKit album; no id is minted.
//  2. Without one, resolve the album id as the whole-album move does
//     (`CloudKitMigrationManager.resolveCloudKitAlbumID`): this device's CloudKit
//     album with the same name and key, then a server album whose `encName`
//     decrypts under the key to the same name, then a new random id.
//  3. Save the `EncAlbum` record if the server does not have it, then write the
//     marker file. In that order: a run that dies between the two finds no marker
//     next time, and step 2 finds the saved album by its name. The record is saved
//     without `migrationInProgress`, so every device lists the album at once.
//  4. Write the album's migration plan
//     (`MigrationPlanStore(iCloudDriveMigrationFrom:cloudKitAlbumID:)`), each
//     folder item a pending plan item classified by kind. A device that already
//     lists the CloudKit album gets its `album.json` linked to the folder.
//
//  5. Bring the album and the folder into parity (`ICloudDriveParitySweep`): the
//     folder scanner indexes every file with no CloudKit component as
//     `.iCloudDrive`, then every file whose component is already in CloudKit is
//     passed to the verified delete (`ICloudDriveVerifiedDelete`).
//
//  6. Flip the album list: adopt the CloudKit album with its link to the folder
//     in one `album.json` write (`AlbumManaging.adoptCloudKitAlbum(record:key:linkingICloudDriveFolder:)`,
//     the same write the album-folder walk adopts with). The CloudKit album
//     appears and the folder leaves the list together, with the index already
//     built, so the album never shows empty. Until then the folder is listed as
//     the iCloud Drive album it was, and the walk and the reconciler leave the
//     album to this run (`ICloudDriveAlbumFlipRegistry`).
//
//  Nothing else is written: no media record, and nothing in the folder but the
//  marker. A media record exists in CloudKit only once its bytes do.
//
//  Every run repeats all of it, for a folder that already has a marker too: the
//  index picks up files older builds added, and the sweep removes files whose
//  upload landed but whose delete never happened. A run on an album and folder
//  already in parity changes nothing.
//
//  The run needs the album key (name matching, the record's key fingerprint, the
//  plan's encryption), a network and an available account, so it does nothing
//  while the phone is locked, offline or signed out, or while the app is in the
//  background (a background task run included). It runs on cellular: it moves
//  no media, so only the blob migration it starts waits for Wi-Fi. Until it has
//  run, the album stays a plain iCloud Drive album. On a device without iCloud Drive it
//  does nothing at all and never reads the iCloud Drive container: such a device
//  sees only the album's CloudKit components.
//
//  `runEveryFolder()` runs it for every iCloud Drive album folder on this device,
//  which the app does at launch and whenever an album folder's marker file
//  changes (`CloudKitAlbumsSync`). A prepared album's folder is watched
//  (`ICloudDriveFolderWatches`) and the album is handed to `startBlobMigration`,
//  which moves its media; once it is done, `ICloudDriveAlbumFinish` removes the
//  folder and stops the watch. `runEveryFolder()` also finishes every album whose
//  linked folder is gone, removed on another device or by a run that died
//  before it deleted the plan and dropped the link.
//
//  A marker it cannot read as one album is never replaced by a new id, which
//  would split the folder into two albums: an evicted marker has its download
//  requested, and a conflicted or unreadable one is left to the album-folder walk.
//  A marker naming an album whose record is gone, or not visible yet, is left as
//  it is (`ICloudDriveAlbumAdoptionState`), so a deleted album is never saved
//  again.
//
//  Before the plan is written, and again before the flip, the marker file is
//  read again and must still name the album. Conflicting markers written by two devices are
//  resolved by the walk to the album that sorts first; a run that finds the
//  marker changed stops, and the next run follows the marker.
//

import Foundation

@MainActor
public final class ICloudDriveAlbumMigration: DebugPrintable {

    /// What a run did for one album.
    public enum AlbumMigrationRunOutcome: Equatable, Sendable {
        /// The folder is linked to the CloudKit album `albumID` on this device, the
        /// album's migration plan is written, and the album list shows the CloudKit
        /// album in the folder's place.
        case prepared(albumID: String)
        /// Nothing was written this run. The album stays a plain iCloud Drive album
        /// unless an earlier run already prepared it.
        case skipped(MigrationSkipReason)
    }

    public enum MigrationSkipReason: Equatable, Sendable {
        case locked
        /// No network. `CloudKitAlbumsSync` runs the step again when the network
        /// changes.
        case offline
        case accountUnavailable
        /// The folder is not an iCloud Drive album on this device.
        case albumNotFound
        /// Only the marker's iCloud placeholder is here. Its download was requested.
        case markerEvicted
        /// The marker has unresolved conflict versions, which the walk resolves.
        case markerConflicted
        /// The marker does not decode, or is in a newer format.
        case markerUnreadable
        /// The marker names an album this device saw published whose record is gone.
        case recordGone(albumID: String)
        /// The marker names an album whose record this device cannot see yet.
        case recordNotVisibleYet(albumID: String)
        /// The marker names an album this device has queued for deletion or
        /// deleted (`DeletedCloudKitAlbums`).
        case deletePending(albumID: String)
        /// No key on this device opens the album record's name.
        case noMatchingKey(albumID: String)
        /// The marker no longer named `albumID` when the plan was to be written or
        /// the album list flipped.
        case markerChanged(albumID: String)
        /// iCloud Drive is off for the app on this device.
        case iCloudDriveUnavailable
        /// The app is in the background.
        case inBackground
        /// A server call or a write failed; `step` names which.
        case failed(step: String, error: String)

        /// Whether the run waits for a network.
        public var waitsForNetwork: Bool { self == .offline }

        init(_ unmet: MigrationDeviceConditions.Unmet) {
            switch unmet {
            case .iCloudDriveUnavailable: self = .iCloudDriveUnavailable
            case .inBackground: self = .inBackground
            case .locked: self = .locked
            case .offline: self = .offline
            }
        }
    }

    /// When a run may do anything.
    public struct MigrationDeviceConditions {
        public var isUnlocked: @MainActor () -> Bool
        public var hasNetwork: () -> Bool
        /// Whether the blob migration may transfer on the current network: an
        /// unmetered one (`NetworkMonitor.isOnUnmeteredNetwork`: Wi-Fi or wired,
        /// not cellular, Personal Hotspot or Low Data Mode), or any connected one
        /// while `ICloudDriveBlobMigrationCellularPreference` allows cellular. Only the blob
        /// migration reads it; `unmet()` does not.
        public var isOnUnmeteredNetwork: () -> Bool
        public var hasICloudDrive: () -> Bool
        public var isInBackground: @MainActor () -> Bool

        public init(isUnlocked: @escaping @MainActor () -> Bool,
                    hasNetwork: @escaping () -> Bool,
                    isOnUnmeteredNetwork: @escaping () -> Bool,
                    hasICloudDrive: @escaping () -> Bool = MigrationDeviceConditions.deviceHasICloudDrive,
                    isInBackground: @escaping @MainActor () -> Bool = { false }) {
            self.isUnlocked = isUnlocked
            self.hasNetwork = hasNetwork
            self.isOnUnmeteredNetwork = isOnUnmeteredNetwork
            self.hasICloudDrive = hasICloudDrive
            self.isInBackground = isInBackground
        }

        /// This device: iCloud Drive on for the app, the app in the foreground,
        /// protected data available, and a network path, which may be metered.
        public static var device: MigrationDeviceConditions {
            MigrationDeviceConditions(isUnlocked: { ProtectedDataAvailability.isAvailable },
                       hasNetwork: { NetworkMonitor.shared.isConnected },
                       isOnUnmeteredNetwork: { ICloudDriveBlobMigrationCellularPreference.permitsTransferNow },
                       hasICloudDrive: deviceHasICloudDrive,
                       isInBackground: { AppRunState.isInBackground })
        }

        /// Whether this device's iCloud Drive container is reachable for the app.
        public static func deviceHasICloudDrive() -> Bool {
            DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) == .available
        }

        /// A condition that does not hold.
        public enum Unmet: Equatable, Sendable {
            case iCloudDriveUnavailable
            case inBackground
            case locked
            case offline
        }

        /// The first condition that does not hold now, nil when all do. iCloud
        /// Drive is checked first, before anything reads its container.
        @MainActor
        public func unmet() -> Unmet? {
            guard hasICloudDrive() else { return .iCloudDriveUnavailable }
            guard !isInBackground() else { return .inBackground }
            guard isUnlocked() else { return .locked }
            guard hasNetwork() else { return .offline }
            return nil
        }
    }

    /// What `runEveryFolder()` did.
    public enum AlbumMigrationPassResult: Equatable, Sendable {
        /// No folder was looked at.
        case skipped(MigrationSkipReason)
        /// Each folder's run, keyed by folder.
        case ran([URL: AlbumMigrationRunOutcome])
    }

    private let albumManager: AlbumManaging
    private let makeStore: () -> CloudKitMediaStoring
    private let materializer: ICloudDriveMaterializing
    private let publishRegistry: CloudKitAlbumPublishRegistry
    private let deleteQueue: CloudKitAlbumDeleteQueue
    private let conditions: MigrationDeviceConditions
    private let requestMarkerDownload: (URL) -> Void
    private let conflictVersions: (URL) -> [URL]
    private let writeMarkerFile: (ICloudDriveAlbumMarkerFile, URL) throws -> Void
    private let makeVerifiedDelete: (CloudKitMediaStoring) -> ICloudDriveComponentDeleting
    private let flipRegistry: ICloudDriveAlbumFlipRegistry
    private let zoneWalkRequests: CloudKitZoneWalkRequests
    private let albumFolders: () -> [URL]
    private let startBlobMigration: @MainActor (_ albumID: String, _ folder: URL) async -> Void
    private let folderWatches: ICloudDriveFolderWatches
    private let makeFolderChangeSource: @MainActor () -> ICloudDriveFolderChangeSource
    private let albumFinish: ICloudDriveAlbumFinish
    private let albumDeletion: ICloudDriveAlbumDeletion
    private var store: CloudKitMediaStoring?

    /// - Parameters:
    ///   - makeStore: builds the CloudKit store, once a run passes its conditions.
    ///   - materializer: reads the true sizes of evicted files for the plan.
    ///   - requestMarkerDownload: asks iCloud to download an evicted marker, given
    ///     the marker's materialized URL.
    ///   - conflictVersions: the unresolved conflict versions of a marker file.
    ///   - writeMarkerFile: writes the marker into the album folder.
    ///   - makeVerifiedDelete: the verified delete the parity sweep passes files to,
    ///     given the run's store.
    ///   - flipRegistry: where the run holds the albums whose flip it owns.
    ///   - zoneWalkRequests: where the run asks the sync to walk the whole zone
    ///     for an album whose index it creates.
    ///   - albumFolders: the iCloud Drive album folders `runEveryFolder()` runs for.
    ///   - startBlobMigration: moves a prepared album's media from its folder
    ///     into CloudKit. Called after every run that ends `.prepared`.
    ///   - folderWatches: where a prepared album's folder watch is kept.
    ///   - makeFolderChangeSource: what a folder watch listens to.
    ///   - finish: finishes an album whose linked folder is gone.
    ///   - albumDeletion: the albums deleted on this device, whose folders are
    ///     removed rather than run.
    public init(albumManager: AlbumManaging,
                makeStore: @escaping () -> CloudKitMediaStoring = { CloudKitStoreProvider.makeStore("iCloudDriveAlbumMigration") },
                materializer: ICloudDriveMaterializing? = nil,
                publishRegistry: CloudKitAlbumPublishRegistry = CloudKitAlbumPublishRegistry(),
                deleteQueue: CloudKitAlbumDeleteQueue = CloudKitAlbumDeleteQueue(),
                conditions: MigrationDeviceConditions = .device,
                requestMarkerDownload: @escaping (URL) -> Void = { ICloudDriveAlbumFolderWalk.requestDownload(ofMarker: $0) },
                conflictVersions: @escaping (URL) -> [URL] = { ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of: $0) },
                writeMarkerFile: @escaping (ICloudDriveAlbumMarkerFile, URL) throws -> Void = { try $0.write(toAlbumDirectory: $1) },
                makeVerifiedDelete: @escaping (CloudKitMediaStoring) -> ICloudDriveComponentDeleting = { ICloudDriveVerifiedDelete(store: $0) },
                flipRegistry: ICloudDriveAlbumFlipRegistry = .shared,
                zoneWalkRequests: CloudKitZoneWalkRequests = CloudKitZoneWalkRequests(),
                albumFolders: (() -> [URL])? = nil,
                startBlobMigration: @escaping @MainActor (_ albumID: String, _ folder: URL) async -> Void = { _, _ in },
                folderWatches: ICloudDriveFolderWatches = .shared,
                makeFolderChangeSource: @escaping @MainActor () -> ICloudDriveFolderChangeSource = { ICloudDriveFolderMetadataQuery() },
                finish: ICloudDriveAlbumFinish? = nil,
                albumDeletion: ICloudDriveAlbumDeletion = .shared) {
        self.albumManager = albumManager
        self.makeStore = makeStore
        self.materializer = materializer ?? ICloudDriveMaterializer()
        self.publishRegistry = publishRegistry
        self.deleteQueue = deleteQueue
        self.conditions = conditions
        self.requestMarkerDownload = requestMarkerDownload
        self.conflictVersions = conflictVersions
        self.writeMarkerFile = writeMarkerFile
        self.makeVerifiedDelete = makeVerifiedDelete
        self.flipRegistry = flipRegistry
        self.zoneWalkRequests = zoneWalkRequests
        self.albumFolders = albumFolders ?? { ICloudDriveAlbumFolderWalk.albumFolders() }
        self.startBlobMigration = startBlobMigration
        self.folderWatches = folderWatches
        self.makeFolderChangeSource = makeFolderChangeSource
        self.albumFinish = finish ?? ICloudDriveAlbumFinish(albumManager: albumManager, folderWatches: folderWatches)
        self.albumDeletion = albumDeletion
    }

    // MARK: - Entry points

    /// Runs for every iCloud Drive album folder on this device, folders whose
    /// marker already names an album included, one after another. Lists no folder
    /// unless a run may do anything now. First removes every folder whose marker
    /// names an album deleted on this device.
    public func runEveryFolder() async -> AlbumMigrationPassResult {
        if let reason = await unmetCondition() {
            _ = skip(reason)
            return .skipped(reason)
        }
        await albumDeletion.removeLeftoverFolders(in: albumFolders())
        var outcomes: [URL: AlbumMigrationRunOutcome] = [:]
        let folders = albumFolders()
        for folder in folders {
            outcomes[folder] = await run(folder: folder)
        }
        await completeRemovedFolders(listed: folders)
        let prepared = outcomes.values.filter { if case .prepared = $0 { true } else { false } }.count
        printDebug("runEveryFolder ok folders=\(outcomes.count) prepared=\(prepared)")
        return .ran(outcomes)
    }

    /// Runs for the iCloud Drive album folder `folder`, as
    /// `ICloudDriveAlbumFolderWalk.albumFolders()` lists it.
    public func run(folder: URL) async -> AlbumMigrationRunOutcome {
        guard conditions.hasICloudDrive() else { return skip(.iCloudDriveUnavailable) }
        guard let album = iCloudDriveAlbum(at: folder) else { return skip(.albumNotFound) }
        return await run(album: album, folder: folder)
    }

    /// Runs for the iCloud Drive album `album`.
    public func run(album: Album) async -> AlbumMigrationRunOutcome {
        guard conditions.hasICloudDrive() else { return skip(.iCloudDriveUnavailable) }
        guard album.storageOption == .icloud,
              let folder = albumManager.storageModel(for: album)?.baseURL else { return skip(.albumNotFound) }
        return await run(album: album, folder: folder)
    }

    /// Runs for one folder while holding `FolderGate` for it, so a second run for
    /// the same folder (the sync's pass and a user's start, which build separate
    /// instances) waits, then reads the marker the first wrote and joins its album
    /// rather than minting another.
    private func run(album: Album, folder: URL) async -> AlbumMigrationRunOutcome {
        let gateKey = folder.standardizedFileURL.resolvingSymlinksInPath().path
        await FolderGate.shared.acquire(gateKey)
        defer { FolderGate.shared.release(gateKey) }
        return await runHoldingGate(album: album, folder: folder)
    }

    private func runHoldingGate(album: Album, folder: URL) async -> AlbumMigrationRunOutcome {
        if let reason = await unmetCondition() { return skip(reason) }
        let store = currentStore()

        let claims = FlipClaims(registry: flipRegistry)
        let outcome: AlbumMigrationRunOutcome
        switch await prepare(album: album, folder: folder, store: store, claims: claims) {
        case .stopped(let stopped):
            outcome = stopped
        case .ready(let prepared):
            await bringToParity(prepared, folder: folder, store: store)
            outcome = flip(prepared, folder: folder)
        }
        claims.releaseAll()
        if case .prepared(let albumID) = outcome {
            await watch(albumID: albumID, folder: folder, store: store)
            await startBlobMigration(albumID, folder)
        }
        return outcome
    }

    /// Keeps the prepared album's folder watched, so files older builds add to it
    /// are indexed while it exists. The finish stops the watch when it removes the
    /// folder.
    private func watch(albumID: String, folder: URL, store: CloudKitMediaStoring) async {
        guard let cloudKitAlbum = albumManager.cloudKitAlbum(withID: albumID) else { return }
        let albumManager = albumManager
        let makeChangeSource = makeFolderChangeSource
        await folderWatches.watch(albumID: albumID, folder: folder) {
            ICloudDriveFolderScanner(album: cloudKitAlbum, indexStore: albumManager.mediaIndexStore(for: cloudKitAlbum),
                                     sizeSidecar: albumManager.sizeSidecar(for: cloudKitAlbum), store: store,
                                     changeSource: makeChangeSource(),
                                     linkedFolder: { $0 == albumID ? folder : nil })
        }
    }

    /// Finishes every album on this device whose linked folder is gone: the
    /// device that finished the album removed it, here or on another device, and
    /// the plan or the link outlived it. An album a listed folder's marker names
    /// is not finished, even when its linked path is gone.
    private func completeRemovedFolders(listed folders: [URL]) async {
        guard let named = extractAlbumIDsInFolderMarkersIfAllReadable(in: folders) else { return }
        for entry in CloudKitAlbumMarker.all() where !named.contains(entry.albumID) {
            guard let linked = entry.marker.linkedICloudDriveFolderURL() else { continue }
            let folderGone = !FileManager.default.fileExists(atPath: linked.path)
            guard folderGone, !ICloudDriveBlobMigration.isRunning(albumID: entry.albumID) else { continue }
            printDebug("linked folder gone albumID=\(entry.albumID)")
            await albumFinish.completeRemovedFolder(albumID: entry.albumID)
        }
    }

    /// The album IDs the markers in `folders` name, or nil when any marker cannot
    /// be read: that folder may be a linked one an older build renamed, so the
    /// album it names is unknown and no album can be finished safely.
    private func extractAlbumIDsInFolderMarkersIfAllReadable(in folders: [URL]) -> Set<String>? {
        var named = Set<String>()
        for folder in folders {
            switch readMarker(in: folder) {
            case .absent: continue
            case .present(let marker): named.insert(marker.albumID)
            case .evicted, .conflicted, .unreadable: return nil
            }
        }
        return named
    }

    /// The first condition that keeps a run from doing anything now, checked
    /// before anything reads the iCloud Drive container or reaches the server
    /// beyond the account check.
    private func unmetCondition() async -> MigrationSkipReason? {
        if let unmet = conditions.unmet() { return MigrationSkipReason(unmet) }
        guard await currentStore().accountAvailable() else { return .accountUnavailable }
        return nil
    }

    /// What steps 1 to 4 hand to the parity sweep and the flip.
    private struct Prepared {
        let albumID: String
        /// The CloudKit album the folder's media is indexed into: as the album list
        /// shows it, or as it will once flipped. Nil when this device has the
        /// album's `album.json` but no key that opens it.
        let cloudKitAlbum: Album?
        /// The record and key the flip adopts. Nil when this device already lists
        /// the album, so there is nothing left to flip.
        let adoption: (record: CloudKitAlbumMetadata, key: PrivateKey)?
    }

    private enum Preparation {
        case ready(Prepared)
        case stopped(AlbumMigrationRunOutcome)
    }

    /// One run at a time per album folder, across every `ICloudDriveAlbumMigration`
    /// in the process. Waiters are let in in arrival order; a release hands the
    /// folder straight to the next waiter.
    @MainActor
    final class FolderGate {
        static let shared = FolderGate()

        private var held: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func acquire(_ key: String) async {
            if held.insert(key).inserted { return }
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }

        func release(_ key: String) {
            guard var queue = waiters[key], !queue.isEmpty else {
                held.remove(key)
                return
            }
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        }
    }

    /// The albums one run holds in the flip registry, released when the run ends.
    private final class FlipClaims {
        private let registry: ICloudDriveAlbumFlipRegistry
        private var held: [String] = []

        init(registry: ICloudDriveAlbumFlipRegistry) {
            self.registry = registry
        }

        func hold(_ albumID: String) {
            registry.begin(albumID)
            held.append(albumID)
        }

        func releaseAll() {
            held.forEach(registry.end)
            held = []
        }
    }

    /// Steps 1 to 4: the CloudKit album, the marker and the plan.
    private func prepare(album: Album, folder: URL, store: CloudKitMediaStoring, claims: FlipClaims) async -> Preparation {
        switch readMarker(in: folder) {
        case .evicted:
            requestMarkerDownload(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder))
            return stop(.markerEvicted)
        case .conflicted:
            return stop(.markerConflicted)
        case .unreadable:
            return stop(.markerUnreadable)
        case .present(let marker):
            return await joinMarkedAlbum(marker, album: album, folder: folder, store: store, claims: claims)
        case .absent:
            return await createMarkedAlbum(album: album, folder: folder, store: store, claims: claims)
        }
    }

    // MARK: - Steps

    /// A marker names the album: adopt it, or leave the folder alone when its
    /// record cannot be adopted.
    private func joinMarkedAlbum(_ marker: ICloudDriveAlbumMarkerFile,
                                 album: Album,
                                 folder: URL,
                                 store: CloudKitMediaStoring,
                                 claims: FlipClaims) async -> Preparation {
        var adoptionState = classify(marker, lookup: .notFetched)
        if case .needsFetch(let albumID) = adoptionState {
            adoptionState = classify(marker, lookup: await lookUp(albumID, store: store))
        }
        switch adoptionState {
        case .adopted(let albumID):
            return await linkAndPlan(albumID: albumID, record: nil, createdByMove: false, album: album, folder: folder)
        case .adoptable(let record):
            claims.hold(record.albumID)
            publishRegistry.markConfirmedOnServer(record.albumID)
            return await linkAndPlan(albumID: record.albumID, record: record, createdByMove: false,
                                     album: album, folder: folder)
        case .recordGone(let albumID):
            return stop(.recordGone(albumID: albumID))
        case .recordNotVisibleYet(let albumID):
            return stop(.recordNotVisibleYet(albumID: albumID))
        case .deletePending(let albumID):
            return stop(.deletePending(albumID: albumID))
        case .lookupFailed:
            return stop(.failed(step: "fetchAlbum", error: "lookup failed"))
        case .noMarker, .needsFetch, .markerEvicted, .markerConflicted, .markerUnreadable:
            return stop(.markerUnreadable)
        }
    }

    /// No marker: resolve the album id, save the record if the server lacks it,
    /// then write the marker.
    private func createMarkedAlbum(album: Album,
                                   folder: URL,
                                   store: CloudKitMediaStoring,
                                   claims: FlipClaims) async -> Preparation {
        let albumID: String
        let minted: Bool
        do {
            (albumID, minted) = try await CloudKitMigrationManager.resolveCloudKitAlbumID(for: album, store: store,
                                                                                         deleteQueue: deleteQueue)
        } catch {
            return stop(.failed(step: "resolveAlbumID", error: "\(error)"))
        }
        claims.hold(albumID)

        let record: CloudKitAlbumMetadata
        do {
            if let existing = try await savedAlbum(albumID: albumID, store: store) {
                record = existing
            } else {
                let twin = Album.cloudKitTwin(of: album, albumID: albumID)
                guard let fingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: twin,
                                                                                keyManager: albumManager.keyManager) else {
                    return stop(.noMatchingKey(albumID: albumID))
                }
                let upload = CloudKitMigrationManager.albumUpload(for: twin, source: album, albumID: albumID,
                                                                  scope: .album, keyFingerprint: fingerprint,
                                                                  migrationInProgress: nil,
                                                                  albumManager: albumManager)
                try await store.saveAlbum(upload)
                record = CloudKitAlbumMetadata(albumID: upload.albumID, encName: upload.encName,
                                               createdAt: upload.createdAt, isHidden: upload.isHidden,
                                               schemaVersion: upload.schemaVersion,
                                               keyFingerprint: upload.keyFingerprint,
                                               recordChangeTag: nil, coverMediaID: upload.coverMediaID)
                printDebug("run saved album record albumID=\(albumID) minted=\(minted)")
            }
        } catch {
            return stop(.failed(step: "saveAlbum", error: "\(error)"))
        }
        publishRegistry.markConfirmedOnServer(albumID)

        do {
            try writeMarkerFile(ICloudDriveAlbumMarkerFile(albumID: albumID), folder)
        } catch {
            return stop(.failed(step: "writeMarkerFile", error: "\(error)"))
        }
        return await linkAndPlan(albumID: albumID, record: record, createdByMove: minted, album: album, folder: folder)
    }

    /// The album's record, or nil when the server has none. A zone that does not
    /// exist yet holds no album, so it reads as nil too: the `saveAlbum` that
    /// follows creates the zone.
    private func savedAlbum(albumID: String, store: CloudKitMediaStoring) async throws -> CloudKitAlbumMetadata? {
        do {
            return try await store.fetchAlbum(albumID: albumID)
        } catch CloudKitMediaStoreError.zoneNotFound {
            printDebug("run no zone yet albumID=\(albumID) — saving the album creates it")
            return nil
        }
    }

    /// Writes the migration plan once the marker file still names `albumID`, and
    /// links `album.json` to the folder on a device that already lists the album.
    /// `record` is needed only when this device has no `album.json` for the album
    /// yet: the flip writes one from it after the parity sweep.
    private func linkAndPlan(albumID: String,
                             record: CloudKitAlbumMetadata?,
                             createdByMove: Bool,
                             album: Album,
                             folder: URL) async -> Preparation {
        guard case .present(let current) = readMarker(in: folder), current.albumID == albumID else {
            return stop(.markerChanged(albumID: albumID))
        }

        let prepared: Prepared
        if CloudKitAlbumMarker.exists(albumID: albumID) {
            do {
                try CloudKitAlbumMarker.linkICloudDriveFolder(folder, albumID: albumID)
            } catch {
                return stop(.failed(step: "linkFolder", error: "\(error)"))
            }
            prepared = Prepared(albumID: albumID, cloudKitAlbum: albumManager.cloudKitAlbum(withID: albumID),
                                adoption: nil)
        } else {
            guard let record else { return stop(.failed(step: "adopt", error: "no record")) }
            let keys = [album.key] + ((try? albumManager.keyManager.storedKeys()) ?? [])
            guard let match = CloudKitAlbumReconciler.match(record: record, keys: keys) else {
                return stop(.noMatchingKey(albumID: albumID))
            }
            let cloudKitAlbum = Album(encryptedName: record.encName, storageOption: .cloudKit,
                                      creationDate: record.createdAt, key: match.key, albumID: record.albumID)
            prepared = Prepared(albumID: albumID, cloudKitAlbum: cloudKitAlbum, adoption: (record, match.key))
        }

        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: album, cloudKitAlbumID: albumID)
        let existing = await planStore.load()
        let enumerated = await CloudKitMigrationManager.enumerateItems(album: album, albumManager: albumManager,
                                                                       materializer: materializer)
        do {
            let plan = try MigrationPlan.album(album,
                                               items: CloudKitMigrationManager.merge(existing: existing?.items ?? [],
                                                                                     enumerated: enumerated),
                                               createdAt: existing?.createdAt ?? Date(),
                                               cloudKitAlbumID: albumID,
                                               cloudKitAlbumCreatedByMove: existing?.destination.createdByMove ?? createdByMove)
            try await planStore.save(plan)
            printDebug("run prepared albumID=\(albumID) items=\(plan.items.count)")
        } catch {
            return stop(.failed(step: "savePlan", error: "\(error)"))
        }
        return .ready(prepared)
    }

    /// Step 5: indexes the folder's files into the CloudKit album and passes every
    /// file whose component is in CloudKit to the verified delete. The folder is
    /// given to the scanner directly, since an album not flipped yet has no
    /// `album.json` to link it.
    private func bringToParity(_ prepared: Prepared, folder: URL, store: CloudKitMediaStoring) async {
        let albumID = prepared.albumID
        guard let cloudKitAlbum = prepared.cloudKitAlbum else {
            printDebug("parity skipped albumID=\(albumID) — no key opens the CloudKit album")
            return
        }
        if !FileManager.default.fileExists(atPath: MediaIndexStore.indexURL(for: cloudKitAlbum).path) {
            // The scan creates the album's index. Records other devices uploaded
            // before this device knew the album lie behind the zone cursor, and the
            // sync walks the whole zone only for an album without an index.
            zoneWalkRequests.request(albumID)
        }
        let indexStore = albumManager.mediaIndexStore(for: cloudKitAlbum)
        let scanner = ICloudDriveFolderScanner(album: cloudKitAlbum, indexStore: indexStore,
                                               sizeSidecar: albumManager.sizeSidecar(for: cloudKitAlbum),
                                               store: store,
                                               linkedFolder: { $0 == albumID ? folder : nil })
        let sweep = ICloudDriveParitySweep(scanner: scanner, indexStore: indexStore,
                                           verifiedDelete: makeVerifiedDelete(store))
        await sweep.run(albumID: albumID, folder: folder)
    }

    /// Step 6: adopts the CloudKit album with its link to the folder in the one
    /// `album.json` write that swaps the folder for the album in the album list.
    /// A marker that no longer names the album stops the run before the write,
    /// and the plan and index written for the album are removed: this device
    /// never listed it, and the next run follows the marker.
    private func flip(_ prepared: Prepared, folder: URL) -> AlbumMigrationRunOutcome {
        let albumID = prepared.albumID
        guard let adoption = prepared.adoption else { return .prepared(albumID: albumID) }
        guard case .present(let current) = readMarker(in: folder), current.albumID == albumID else {
            if !CloudKitAlbumMarker.exists(albumID: albumID) {
                discardUnflippedState(albumID: albumID, cloudKitAlbum: prepared.cloudKitAlbum)
            }
            return skip(.markerChanged(albumID: albumID))
        }
        if CloudKitAlbumMarker.exists(albumID: albumID) {
            do {
                try CloudKitAlbumMarker.linkICloudDriveFolder(folder, albumID: albumID)
            } catch {
                return skip(.failed(step: "linkFolder", error: "\(error)"))
            }
            return .prepared(albumID: albumID)
        }
        albumManager.adoptCloudKitAlbum(record: adoption.record, key: adoption.key, linkingICloudDriveFolder: folder)
        guard CloudKitAlbumMarker.exists(albumID: albumID) else {
            return skip(.failed(step: "adopt", error: "album.json not written"))
        }
        printDebug("run flipped albumID=\(albumID)")
        return .prepared(albumID: albumID)
    }

    private func discardUnflippedState(albumID: String, cloudKitAlbum: Album?) {
        MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        guard let cloudKitAlbum else { return }
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: cloudKitAlbum))
        AlbumStoreRegistry.shared.drop(albumWithID: cloudKitAlbum.id)
    }

    // MARK: - Helpers

    private func currentStore() -> CloudKitMediaStoring {
        let store = self.store ?? makeStore()
        self.store = store
        return store
    }

    private func readMarker(in folder: URL) -> ICloudDriveAlbumMarkerFile.ReadResult {
        ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder, conflictVersions: conflictVersions)
    }

    private func classify(_ marker: ICloudDriveAlbumMarkerFile,
                          lookup: ICloudDriveAlbumRecordLookup) -> ICloudDriveAlbumAdoptionState {
        ICloudDriveAlbumAdoptionState.classify(marker: .present(marker),
                                               isAdopted: { CloudKitAlbumMarker.exists(albumID: $0) },
                                               isDeletePending: { [deleteQueue, albumDeletion] in
                                                   deleteQueue.pending().contains($0) || albumDeletion.deletedAlbums.contains($0)
                                               },
                                               lookup: lookup,
                                               isPublished: { [publishRegistry] in publishRegistry.isPublished($0) })
    }

    private func lookUp(_ albumID: String, store: CloudKitMediaStoring) async -> ICloudDriveAlbumRecordLookup {
        do {
            guard let record = try await store.fetchAlbum(albumID: albumID) else { return .notFound }
            return .found(record)
        } catch {
            printDebug("lookUp FAILED albumID=\(albumID) error=\(error)")
            return .failed
        }
    }

    /// The iCloud Drive album whose folder is `folder`: the one the album list
    /// shows, or, for a folder already linked (and so no longer listed), the album
    /// the folder's name and the linked CloudKit album's key make.
    private func iCloudDriveAlbum(at folder: URL) -> Album? {
        let path = CloudKitAlbumMarker.iCloudDriveFolderPath(for: folder)
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        if let listed = albums.first(where: { album in
            album.storageOption == .icloud
                && albumManager.storageModel(for: album).flatMap { CloudKitAlbumMarker.iCloudDriveFolderPath(for: $0.baseURL) } == path
        }) {
            return listed
        }
        guard case .present(let marker) = readMarker(in: folder),
              let cloudKitAlbum = albums.first(where: { $0.storageOption == .cloudKit && $0.albumID == marker.albumID }) else {
            return nil
        }
        return Self.linkedFolderAlbum(folder, cloudKitAlbum: cloudKitAlbum)
    }

    /// The iCloud Drive album a folder linked to `cloudKitAlbum` makes: the folder's
    /// name, the CloudKit album's key, and the folder's creation date, else the
    /// CloudKit album's.
    static func linkedFolderAlbum(_ folder: URL, cloudKitAlbum: Album) -> Album {
        let creationDate = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date
        return Album(encryptedName: folder.lastPathComponent, storageOption: .icloud,
                     creationDate: creationDate ?? cloudKitAlbum.creationDate, key: cloudKitAlbum.key)
    }

    /// Posted on `NotificationCenter.default` each time a run, or
    /// `runEveryFolder()`, skips for want of a network (`MigrationSkipReason.waitsForNetwork`).
    public static let didWaitForNetwork = Notification.Name("ICloudDriveAlbumMigration.didWaitForNetwork")

    private func skip(_ reason: MigrationSkipReason) -> AlbumMigrationRunOutcome {
        printDebug("run skipped reason=\(Self.logName(reason))")
        if reason.waitsForNetwork {
            NotificationCenter.default.post(name: Self.didWaitForNetwork, object: nil)
        }
        return .skipped(reason)
    }

    private func stop(_ reason: MigrationSkipReason) -> Preparation {
        .stopped(skip(reason))
    }

    /// The reason without folder names, which can be plaintext album names.
    private static func logName(_ reason: MigrationSkipReason) -> String {
        switch reason {
        case .failed(let step, let error): return "failed step=\(step) error=\(error)"
        case .recordGone(let id): return "recordGone albumID=\(id)"
        case .recordNotVisibleYet(let id): return "recordNotVisibleYet albumID=\(id)"
        case .deletePending(let id): return "deletePending albumID=\(id)"
        case .noMatchingKey(let id): return "noMatchingKey albumID=\(id)"
        case .markerChanged(let id): return "markerChanged albumID=\(id)"
        default: return "\(reason)"
        }
    }
}

/// The CloudKit albums an `ICloudDriveAlbumMigration` run on this device is
/// preparing and will flip into the album list itself, once the album's index is
/// built. The album-folder walk and the album reconciler leave such an album
/// unadopted while a run holds it: adopting it early would list it before its
/// media is indexed. The run releases the album when it ends, flipped or not, so
/// anything it leaves undone is adopted as before. Held in memory only: a run that
/// dies with the process holds nothing.
public final class ICloudDriveAlbumFlipRegistry: @unchecked Sendable {

    public static let shared = ICloudDriveAlbumFlipRegistry()

    private let lock = NSLock()
    /// Album id to the number of runs holding it.
    private var holds: [String: Int] = [:]

    public init() {}

    func begin(_ albumID: String) {
        lock.withLock { holds[albumID, default: 0] += 1 }
    }

    func end(_ albumID: String) {
        lock.withLock {
            guard let count = holds[albumID] else { return }
            holds[albumID] = count > 1 ? count - 1 : nil
        }
    }

    /// Whether a migration run holds the album's flip.
    public func isHeld(_ albumID: String) -> Bool {
        lock.withLock { holds[albumID] != nil }
    }
}
