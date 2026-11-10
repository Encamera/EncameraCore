//
//  ICloudDriveAlbumFinish.swift
//  EncameraCore
//
//  Ends an iCloud Drive album's move into its CloudKit album. The album is done
//  when its migration plan has no item left to work on, deferred items included,
//  every component in its index is `.cloudKit`, and its iCloud Drive folder
//  holds nothing but the marker file. The folder is then removed with its marker,
//  the plan deleted, the local marker's folder link dropped and the folder's watch
//  stopped. What is left is a plain CloudKit album: no plan, no link, no
//  `.iCloudDrive` component, no pass, no pause (`isPartlyOnICloudDrive`).
//
//  A deferred item keeps its file in the folder, where it is still read from
//  until a later pass moves it, so the folder stays.
//
//  The folder must be empty in every form. Its listing on disk counts every
//  entry but the marker, hidden files and `.icloud` placeholders included, and
//  `NSMetadataQuery` must report nothing either, which covers a file iCloud knows
//  of that has not reached this device's listing. A listing that cannot be read
//  keeps the folder. The removal is a coordinated delete of the folder that
//  lists it once more inside the coordinated block and removes nothing if
//  anything new is there. That narrows, but does not close, the window in which
//  an older build on another device adds a file this device has not heard of yet.
//
//  The order is: remove the folder, stop its watch, delete the plan, drop the
//  link. A process that dies after the folder is removed leaves a link to a
//  folder that is gone, with or without the plan; the album step finishes such an
//  album on its next run (`completeRemovedFolder`), as it does on any other device
//  whose linked folder went because the device that finished removed it. The
//  folder walk leaves a link to a missing folder as it is and lists the CloudKit
//  album either way, so no crash point shows two albums or none.
//
//  Nothing watches the folder once it is removed, and nothing watches for it to
//  come back. An older build that writes into the album afterwards recreates the
//  folder without a marker, so the walk reads it as a plain iCloud Drive album and
//  the album step migrates it like any other folder, which can make it a second
//  album. That duplicate is accepted rather than keeping a watch on every finished
//  album forever.
//

import Foundation

// MARK: - Folder contents seam

/// Reads an album folder's contents in every form and removes it. A protocol so
/// the metadata query, which needs a ubiquity container, can be faked.
public protocol ICloudDriveAlbumFolderContents: Sendable {
    /// The names of every entry directly in `folder` on disk, hidden files and
    /// iCloud placeholders included. Nil when the folder cannot be listed.
    func fileSystemNames(in folder: URL) -> [String]?

    /// The names of every item under `folder` that iCloud Drive's metadata
    /// reports, downloaded or not. Nil when the metadata cannot be read.
    func metadataNames(in folder: URL) async -> [String]?

    /// Removes `folder` under a coordinated delete. Inside the coordinated block
    /// the folder is listed again and removed only if `holdsNothingElse` accepts
    /// that listing. Returns whether the folder is gone.
    func removeFolder(_ folder: URL, ifStillHolding holdsNothingElse: ([String]) -> Bool) throws -> Bool
}

/// The real file system, with the metadata read from an `NSMetadataQuery`.
public struct ICloudDriveAlbumFolderDiskContents: ICloudDriveAlbumFolderContents {

    /// How long the metadata query may take to gather before the folder is kept.
    public static let gatherTimeout: TimeInterval = 10

    private let readMetadataNames: @Sendable (URL) async -> [String]?

    /// - Parameter metadataNames: reads the names the metadata reports under a
    ///   folder; the query by default.
    public init(metadataNames: (@Sendable (URL) async -> [String]?)? = nil) {
        self.readMetadataNames = metadataNames ?? { await Self.queryMetadataNames(in: $0) }
    }

    public func fileSystemNames(in folder: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    public func metadataNames(in folder: URL) async -> [String]? {
        await readMetadataNames(folder)
    }

    public func removeFolder(_ folder: URL, ifStillHolding holdsNothingElse: ([String]) -> Bool) throws -> Bool {
        var removed = false
        var removeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder,
                                                         options: .forDeleting,
                                                         error: &coordinationError) { coordinatedURL in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: coordinatedURL.path) else {
                removed = !FileManager.default.fileExists(atPath: coordinatedURL.path)
                return
            }
            guard holdsNothingElse(names) else { return }
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
                removed = true
            } catch {
                removeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
        return removed
    }

    /// The names of the items under `folder` an `NSMetadataQuery` in the
    /// ubiquitous documents scope reports once it has gathered. Nil without a
    /// ubiquity container, or when the gather does not finish in time: a query
    /// that cannot answer must not read as an empty folder.
    ///
    /// Empty for a folder under `iCloudStorageModel.testContainerRootOverride`:
    /// that substituted container is a plain directory iCloud does not track, so
    /// its listing on disk is all there is.
    @MainActor
    public static func queryMetadataNames(in folder: URL, timeout: TimeInterval = gatherTimeout) async -> [String]? {
        if isInSubstitutedContainer(folder, root: iCloudStorageModel.testContainerRootOverride) { return [] }
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, folder.path)
        let gathered: [NSMetadataItem]? = await withCheckedContinuation { continuation in
            let run = GatherRun()
            let finish: @MainActor (Bool) -> Void = { didGather in
                guard run.claim() else { return }
                if let observer = run.observer { NotificationCenter.default.removeObserver(observer) }
                query.disableUpdates()
                let items = didGather ? (query.results as? [NSMetadataItem] ?? []) : nil
                query.stop()
                continuation.resume(returning: items)
            }
            run.observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                  object: query, queue: .main) { _ in
                MainActor.assumeIsolated { finish(true) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(false)
            }
            if !query.start() { finish(false) }
        }
        guard let gathered else { return nil }
        return gathered.compactMap { item -> String? in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let itemPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard itemPath.hasPrefix(folderPath + "/") else { return nil }
            return String(itemPath.dropFirst(folderPath.count + 1))
        }
    }

    /// Whether `folder` lies inside `root`, the substituted iCloud Drive
    /// container, rather than being the container itself or outside it.
    static func isInSubstitutedContainer(_ folder: URL, root: URL?) -> Bool {
        guard let root else { return false }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return folder.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/")
    }

    /// Resumes the gather's continuation once, whichever of the notification and
    /// the deadline comes first.
    @MainActor
    private final class GatherRun {
        var observer: NSObjectProtocol?
        private var isClaimed = false

        func claim() -> Bool {
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }
}

// MARK: - Folder watches

/// The watches on linked iCloud Drive folders in this process, one per CloudKit
/// album, each a folder scanner's `startWatching()`. The album step starts one for
/// every album it prepares, so files older builds add are indexed while the folder
/// exists; the finish stops it when the folder is removed.
@MainActor
public final class ICloudDriveFolderWatches: DebugPrintable {

    nonisolated public static let shared = ICloudDriveFolderWatches()

    private struct Watch {
        let folder: URL
        let scanner: ICloudDriveFolderScanner
    }

    private var watches: [String: Watch] = [:]

    public nonisolated init() {}

    /// Whether the folder of the CloudKit album `albumID` is watched.
    public func isWatching(albumID: String) -> Bool {
        watches[albumID] != nil
    }

    /// Starts watching `folder` for the album `albumID` with the scanner
    /// `makeScanner` builds, unless that folder is already watched for it. A watch
    /// on another folder, one the album was linked to before, is stopped first.
    func watch(albumID: String, folder: URL, makeScanner: @MainActor () -> ICloudDriveFolderScanner) async {
        if let current = watches[albumID] {
            if current.folder.standardizedFileURL == folder.standardizedFileURL { return }
            watches[albumID] = nil
            await current.scanner.stopWatching()
        }
        let scanner = makeScanner()
        watches[albumID] = Watch(folder: folder, scanner: scanner)
        guard await scanner.startWatching() else {
            if watches[albumID]?.scanner === scanner { watches[albumID] = nil }
            return
        }
        printDebug("watch ok albumID=\(albumID)")
    }

    /// Stops the album's watch, if it has one.
    func stop(albumID: String) async {
        guard let current = watches.removeValue(forKey: albumID) else { return }
        await current.scanner.stopWatching()
        printDebug("stop ok albumID=\(albumID)")
    }

    /// Stops every watch.
    func stopAll() async {
        for albumID in Array(watches.keys) {
            await stop(albumID: albumID)
        }
    }
}

// MARK: - Finish

@MainActor
public final class ICloudDriveAlbumFinish: DebugPrintable {

    public enum Outcome: Equatable, Sendable {
        /// The folder was removed, the plan deleted and the link dropped.
        case removed
        /// The folder stays, and with it the plan and the link.
        case kept(KeepReason)
    }

    public enum KeepReason: Equatable, Sendable {
        /// The plan has an item still to move.
        case workRemaining
        /// Every item the plan still has to move is deferred; their files stay in
        /// the folder until a later pass moves them.
        case deferredItems(Int)
        /// The folder's marker does not confirm it belongs to the album.
        case folderNotVerified(ICloudDriveFolderScanSkipReason)
        /// The folder's listing on disk or its metadata could not be read.
        case contentsUnknown
        /// The folder holds entries on disk besides the marker.
        case notEmpty(entries: Int)
        /// iCloud Drive's metadata reports items in the folder besides the marker.
        case placeholdersReported(entries: Int)
        /// The album's index has components still on iCloud Drive.
        case componentsOnICloudDrive(Int)
        /// Something arrived in the folder between the checks and the removal.
        case changedBeforeRemoval
        /// The coordinated delete failed.
        case removeFailed(String)
    }

    private let albumManager: AlbumManaging
    private let folderContents: ICloudDriveAlbumFolderContents
    private let folderWatches: ICloudDriveFolderWatches
    private let markerConflictVersions: @Sendable (URL) -> [URL]

    /// The last outcome of `finish` for each album in this process.
    public private(set) var outcomes: [String: Outcome] = [:]

    /// Posted on the default center once an album is done (`completeRemovedFolder`),
    /// with its id under `"albumID"`. Reads nothing, so it is posted while locked too.
    public static let didComplete = Notification.Name("ICloudDriveAlbumFinish.didComplete")

    /// - Parameters:
    ///   - folderContents: lists the folder in every form and removes it.
    ///   - folderWatches: the watch the finish stops.
    ///   - markerConflictVersions: the unresolved conflict versions of a marker file.
    public init(albumManager: AlbumManaging,
                folderContents: ICloudDriveAlbumFolderContents = ICloudDriveAlbumFolderDiskContents(),
                folderWatches: ICloudDriveFolderWatches = .shared,
                markerConflictVersions: @escaping @Sendable (URL) -> [URL] = { ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of: $0) }) {
        self.albumManager = albumManager
        self.folderContents = folderContents
        self.folderWatches = folderWatches
        self.markerConflictVersions = markerConflictVersions
    }

    /// Whether the CloudKit album `cloudKitAlbum` still has anything on iCloud
    /// Drive: a migration plan, a link to an iCloud Drive folder, an index
    /// component at `.iCloudDrive`, a pass running or a pause held. False for an
    /// album that is done and for one that was always a CloudKit album, which are
    /// then the same; false for an album of any other storage.
    public static func isPartlyOnICloudDrive(_ cloudKitAlbum: Album, albumManager: AlbumManaging) async -> Bool {
        guard cloudKitAlbum.storageOption == .cloudKit, let albumID = cloudKitAlbum.albumID else { return false }
        if MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: albumID) { return true }
        if CloudKitAlbumMarker.read(albumID: albumID)?.iCloudDriveFolderPath != nil { return true }
        if ICloudDriveBlobMigration.isRunning(albumID: albumID) { return true }
        if ICloudDriveBlobMigration.pauseReason(albumID: albumID) != nil { return true }
        let entries = await albumManager.mediaIndexStore(for: cloudKitAlbum).current()?.entries ?? []
        return Self.iCloudDriveComponentCount(entries) > 0
    }

    /// Removes `folder`, the iCloud Drive folder of the CloudKit album `albumID`,
    /// once `plan` (the album's plan as the caller's pass left it), the folder and
    /// the index say the album is done, then completes the album
    /// (`completeRemovedFolder`). Called from the album's pass, so no other pass
    /// runs for it meanwhile.
    @discardableResult
    func finish(albumID: String, folder: URL, plan: MigrationPlan, cloudKitAlbum: Album) async -> Outcome {
        let outcome = await removeFolderIfDone(albumID: albumID, folder: folder, plan: plan,
                                               cloudKitAlbum: cloudKitAlbum)
        outcomes[albumID] = outcome
        printDebug("finish albumID=\(albumID) outcome=\(outcome)")
        if outcome == .removed {
            await completeRemovedFolder(albumID: albumID)
        }
        return outcome
    }

    /// What is left once the album's folder is gone: stops its watch, deletes its
    /// plan, drops its link, forgets any pause held for it, records the album's
    /// move-complete notice and posts `didComplete`. Needs no key.
    func completeRemovedFolder(albumID: String) async {
        await folderWatches.stop(albumID: albumID)
        MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        do {
            try CloudKitAlbumMarker.unlinkICloudDriveFolder(albumID: albumID)
        } catch {
            printDebug("unlink FAILED albumID=\(albumID) error=\(error)")
        }
        ICloudDriveBlobMigration.forgetPause(albumID: albumID)
        CloudKitMoveNotice.markPending(albumID: albumID, kind: .upgradedFromICloudDrive)
        NotificationCenter.default.post(name: Self.didComplete, object: nil, userInfo: ["albumID": albumID])
        printDebug("complete albumID=\(albumID)")
    }

    private func removeFolderIfDone(albumID: String, folder: URL, plan: MigrationPlan,
                                    cloudKitAlbum: Album) async -> Outcome {
        guard !plan.hasRemainingWork else {
            let remaining = plan.items.filter { !$0.state.isDone }.count
            return .kept(plan.deferredCount == remaining ? .deferredItems(remaining) : .workRemaining)
        }
        if case .failure(let skip) = ICloudDriveFolderScanner.verifiedFolder(albumID: albumID,
                                                                             isICloudDriveAvailable: { true },
                                                                             linkedFolder: { _ in folder },
                                                                             markerConflictVersions: markerConflictVersions) {
            return .kept(.folderNotVerified(skip.reason))
        }
        guard let onDisk = folderContents.fileSystemNames(in: folder).map(Self.contents),
              let reported = await folderContents.metadataNames(in: folder).map(Self.contents) else {
            return .kept(.contentsUnknown)
        }
        guard onDisk.isEmpty else { return .kept(.notEmpty(entries: onDisk.count)) }
        guard reported.isEmpty else { return .kept(.placeholdersReported(entries: reported.count)) }
        let entries = await albumManager.mediaIndexStore(for: cloudKitAlbum).reloadFromDisk()?.entries ?? []
        let onICloudDrive = Self.iCloudDriveComponentCount(entries)
        guard onICloudDrive == 0 else { return .kept(.componentsOnICloudDrive(onICloudDrive)) }
        do {
            guard try folderContents.removeFolder(folder, ifStillHolding: { Self.contents($0).isEmpty }) else {
                return .kept(.changedBeforeRemoval)
            }
        } catch {
            return .kept(.removeFailed("\(error)"))
        }
        return .removed
    }

    /// The entries of a listing that are not the marker, in either form.
    private static func contents(_ names: [String]) -> [String] {
        names.filter { !ICloudDriveAlbumMarkerFile.isMarkerFileName($0) }
    }

    private static func iCloudDriveComponentCount(_ entries: [MediaIndexEntry]) -> Int {
        entries.reduce(0) { count, entry in
            count + (entry.hasPhotoComponent && entry.photoLocation == .iCloudDrive ? 1 : 0)
                + (entry.hasVideoComponent && entry.videoLocation == .iCloudDrive ? 1 : 0)
        }
    }
}
