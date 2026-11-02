//
//  ICloudDriveAlbumDeletion.swift
//  EncameraCore
//
//  Removes what a deleted CloudKit album has on iCloud Drive: its linked folder
//  with the marker file, its iCloud Drive migration plan, its folder watch and
//  any pause held for it. `AlbumManager.delete(album:)` and
//  `applyRemoteAlbumDeletion(album:)` run it for every CloudKit album; for an
//  album that was never partly on iCloud Drive every step is a no-op.
//
//  The album record's delete cascades to media records only, so the folder,
//  which holds the only copy of the items not yet in CloudKit, is removed here
//  explicitly. A delete refuses up front, touching nothing, when the album has a
//  component on iCloud Drive and its folder cannot be verified
//  (`folderToRemove(for:)` throws `ICloudDriveItemDeleteError.folderUnavailable`):
//  deleting the album then would orphan those files, or leave them behind as a
//  plain iCloud Drive album.
//
//  The order is:
//
//  1. The album id goes into `DeletedCloudKitAlbums`, durably, before anything is
//     removed. From then on a folder whose marker names the album is not listed,
//     adopted or migrated on this device, and `removeLeftoverFolders()` removes it.
//  2. The album's local state goes (`album.json`, index, previews, sidecars), so
//     the blob migration stops before its next item and the scanner finds no link.
//  3. `removeICloudDriveHalf(albumID:folder:)` stops the pass running for the
//     album and waits for it to end, so the item in flight finishes and
//     checkpoints first; stops the folder watch; removes the folder under a
//     coordinated delete, only while its marker names the album; then removes
//     the plan. The plan file is marked removed in the process before the wait,
//     so no later save of it by the pass or the album step writes it back.
//  4. The caller then issues the album record's delete.
//
//  A process that dies after step 1 leaves a folder this device no longer lists;
//  the next `ICloudDriveAlbumMigration.runEveryFolder()` removes it. A folder whose
//  marker names the album and that comes back later, through another device
//  still syncing it, is removed the same way, and never shows as a plain iCloud
//  Drive album. A folder whose marker names another album is never removed.
//
//  An erase that deletes the media removes every linked folder at once
//  (`removeEveryLinkedFolder()`), whatever album it belongs to, and forgets the
//  deleted albums.
//

import Foundation

/// The CloudKit albums deleted on this device, by the user or through the change
/// feed. Kept for good: a folder whose marker names one of them is never shown or
/// migrated again here. Album ids are random UUIDs, never reused.
public struct DeletedCloudKitAlbums: DebugPrintable {

    private static let storageKey = "cloudkit_deleted_album_ids_v1"
    private static let lock = NSLock()

    private let defaults: UserDefaults

    public init() {
        guard let defaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) else {
            preconditionFailure("No UserDefaults suite named \(UserDefaultUtils.appGroup) — a bundle id cannot be a suite name")
        }
        self.defaults = defaults
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func all() -> Set<String> {
        Self.lock.withLock { Set(defaults.stringArray(forKey: Self.storageKey) ?? []) }
    }

    public func contains(_ albumID: String) -> Bool {
        all().contains(albumID)
    }

    public func insert(_ albumID: String) {
        Self.lock.withLock {
            var set = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
            guard set.insert(albumID).inserted else { return }
            defaults.set(Array(set), forKey: Self.storageKey)
            printDebug("insert ok albumID=\(albumID) count=\(set.count)")
        }
    }

    /// Forgets every deleted album. Only an erase that removes every linked
    /// folder calls it, so no folder of a deleted album is left to hide.
    public func removeAll() {
        Self.lock.withLock { defaults.removeObject(forKey: Self.storageKey) }
    }
}

public final class ICloudDriveAlbumDeletion: @unchecked Sendable, DebugPrintable {

    public static let shared = ICloudDriveAlbumDeletion()

    public let deletedAlbums: DeletedCloudKitAlbums
    private let isICloudDriveAvailable: @Sendable () -> Bool
    private let markerConflictVersions: @Sendable (URL) -> [URL]
    private let folderContents: ICloudDriveAlbumFolderContents
    private let folderWatches: ICloudDriveFolderWatches
    private let albumFolders: @Sendable () -> [URL]

    private let lock = NSLock()
    private var removals: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - deletedAlbums: where deleted album ids are kept.
    ///   - isICloudDriveAvailable: whether this device has iCloud Drive.
    ///   - markerConflictVersions: the unresolved conflict versions of a marker file.
    ///   - folderContents: removes a folder under a coordinated delete.
    ///   - folderWatches: the folder watch stopped for a deleted album.
    ///   - albumFolders: the iCloud Drive album folders `removeLeftoverFolders()` and
    ///     `removeEveryLinkedFolder()` look at.
    public init(deletedAlbums: DeletedCloudKitAlbums = DeletedCloudKitAlbums(),
                isICloudDriveAvailable: @escaping @Sendable () -> Bool = { iCloudStorageModel.isRootAvailable },
                markerConflictVersions: @escaping @Sendable (URL) -> [URL] = { ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of: $0) },
                folderContents: ICloudDriveAlbumFolderContents = ICloudDriveAlbumFolderDiskContents(),
                folderWatches: ICloudDriveFolderWatches = .shared,
                albumFolders: (@Sendable () -> [URL])? = nil) {
        self.deletedAlbums = deletedAlbums
        self.isICloudDriveAvailable = isICloudDriveAvailable
        self.markerConflictVersions = markerConflictVersions
        self.folderContents = folderContents
        self.folderWatches = folderWatches
        self.albumFolders = albumFolders ?? { ICloudDriveAlbumFolderWalk.albumFolders() }
    }

    // MARK: - Before the delete

    /// The verified iCloud Drive folder the CloudKit album `album` links, which its
    /// delete removes, or nil when it links none that can be verified now.
    ///
    /// - Throws: `ICloudDriveItemDeleteError.folderUnavailable` when the album's
    ///   index has a component on iCloud Drive and the folder cannot be verified:
    ///   those files are the only copy of their items.
    public func folderToRemove(for album: Album) throws -> URL? {
        guard album.storageOption == .cloudKit, let albumID = album.albumID else { return nil }
        switch verifiedFolder(albumID: albumID, linkedFolder: CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:)) {
        case .success(let folder):
            return folder
        case .failure(let skip):
            let onICloudDrive = MediaIndexStore.storedEntries(for: album).contains {
                ($0.hasPhotoComponent && $0.photoLocation == .iCloudDrive)
                    || ($0.hasVideoComponent && $0.videoLocation == .iCloudDrive)
            }
            guard !onICloudDrive else {
                printDebug("folderToRemove REFUSED albumID=\(albumID) reason=\(skip.reason)")
                throw ICloudDriveItemDeleteError.folderUnavailable(skip.reason)
            }
            return nil
        }
    }

    /// Records the album `albumID` as deleted on this device. Called before any of
    /// its local state is removed.
    public func markDeleted(albumID: String) {
        deletedAlbums.insert(albumID)
    }

    // MARK: - The removal

    /// Stops the album's blob migration pass and folder watch, removes `folder`
    /// while its marker names the album, and removes the album's iCloud Drive
    /// migration plan. Waits for a pass in flight to end first.
    @MainActor
    public func removeICloudDriveHalf(albumID: String, folder: URL?) async {
        MigrationPlanRemovals.shared.recordRemovedPlan(at: MigrationPlanStore.iCloudDriveMigrationPlanURL(cloudKitAlbumID: albumID))
        await ICloudDriveBlobMigration.stopPass(albumID: albumID)
        await folderWatches.stop(albumID: albumID)
        if let folder {
            removeFolder(folder, ofAlbumID: albumID)
        }
        MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        ICloudDriveBlobMigration.forgetPause(albumID: albumID)
        printDebug("removeICloudDriveHalf ok albumID=\(albumID) folder=\(folder != nil)")
    }

    /// Removes every iCloud Drive album folder whose marker names an album deleted
    /// on this device: one whose removal a killed process never made, or one
    /// another device synced back. Looks at `folders`, or at every album folder.
    /// Returns the folders removed.
    @MainActor
    @discardableResult
    public func removeLeftoverFolders(in folders: [URL]? = nil) async -> [URL] {
        let deleted = deletedAlbums.all()
        guard !deleted.isEmpty, isICloudDriveAvailable() else { return [] }
        var removed: [URL] = []
        for folder in folders ?? albumFolders() {
            guard case .present(let marker) = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder,
                                                                             conflictVersions: markerConflictVersions),
                  deleted.contains(marker.albumID) else { continue }
            await ICloudDriveBlobMigration.stopPass(albumID: marker.albumID)
            await folderWatches.stop(albumID: marker.albumID)
            if removeFolder(folder, ofAlbumID: marker.albumID) { removed.append(folder) }
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: marker.albumID)
        }
        return removed
    }

    // MARK: - Erase

    /// Removes every linked iCloud Drive folder on this device, for an erase that
    /// deletes the media: each folder a local marker links, and each iCloud Drive
    /// album folder holding a marker file in any form, whatever album it names.
    /// For each album it stops the pass and the folder watch, removes the folder
    /// under a coordinated delete, removes the plan, drops any pause and unlinks
    /// the local marker. Every remaining watch is stopped and the deleted albums
    /// are forgotten. Returns the folders removed.
    @MainActor
    @discardableResult
    public func removeEveryLinkedFolder() async -> [URL] {
        guard isICloudDriveAvailable() else { return [] }
        var targets: [(albumID: String?, folder: URL)] = CloudKitAlbumMarker.all().compactMap { entry in
            entry.marker.linkedICloudDriveFolderURL().map { (entry.albumID, $0) }
        }
        for folder in albumFolders() {
            let albumID: String?
            switch ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder, conflictVersions: markerConflictVersions) {
            case .absent: continue
            case .present(let marker): albumID = marker.albumID
            case .evicted, .conflicted, .unreadable: albumID = nil
            }
            targets.append((albumID, folder))
        }

        var seen = Set<String>()
        var removed: [URL] = []
        for target in targets where seen.insert(target.folder.standardizedFileURL.path).inserted {
            if let albumID = target.albumID {
                MigrationPlanRemovals.shared.recordRemovedPlan(at: MigrationPlanStore.iCloudDriveMigrationPlanURL(cloudKitAlbumID: albumID))
                await ICloudDriveBlobMigration.stopPass(albumID: albumID)
                await folderWatches.stop(albumID: albumID)
            }
            do {
                if try folderContents.removeFolder(target.folder, ifStillHolding: { _ in true }) {
                    removed.append(target.folder)
                }
            } catch {
                printDebug("erase removeFolder FAILED albumID=\(target.albumID ?? "-") error=\(error)")
            }
            if let albumID = target.albumID {
                MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
                ICloudDriveBlobMigration.forgetPause(albumID: albumID)
                _ = try? CloudKitAlbumMarker.unlinkICloudDriveFolder(albumID: albumID)
            }
        }
        await folderWatches.stopAll()
        deletedAlbums.removeAll()
        printDebug("removeEveryLinkedFolder ok found=\(seen.count) removed=\(removed.count)")
        return removed
    }

    /// Whether `folder`'s marker names an album deleted on this device, so the
    /// folder is not an album of its own. Decrypts nothing.
    public func isDeletedAlbumFolder(_ folder: URL, deletedAlbumIDs: Set<String>) -> Bool {
        guard !deletedAlbumIDs.isEmpty,
              case .present(let marker) = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder,
                                                                         conflictVersions: markerConflictVersions) else {
            return false
        }
        return deletedAlbumIDs.contains(marker.albumID)
    }

    @discardableResult
    private func removeFolder(_ folder: URL, ofAlbumID albumID: String) -> Bool {
        if case .failure(let skip) = verifiedFolder(albumID: albumID, linkedFolder: { _ in folder }) {
            printDebug("removeFolder skip albumID=\(albumID) reason=\(skip.reason)")
            return false
        }
        do {
            let removed = try folderContents.removeFolder(folder, ifStillHolding: { _ in true })
            printDebug("removeFolder \(removed ? "ok" : "kept") albumID=\(albumID)")
            return removed
        } catch {
            printDebug("removeFolder FAILED albumID=\(albumID) error=\(error)")
            return false
        }
    }

    private func verifiedFolder(albumID: String, linkedFolder: (String) -> URL?) -> Result<URL, ICloudDriveFolderScanner.Skip> {
        ICloudDriveFolderScanner.verifiedFolder(albumID: albumID,
                                                isICloudDriveAvailable: isICloudDriveAvailable,
                                                linkedFolder: linkedFolder,
                                                markerConflictVersions: markerConflictVersions)
    }

    // MARK: - Tracking

    /// Keeps `task`, the rest of the album `albumID`'s delete, until it ends.
    func track(albumID: String, _ task: Task<Void, Never>) {
        lock.withLock { removals[albumID] = task }
    }

    /// Returns once the rest of the album `albumID`'s delete started in this
    /// process has ended.
    public func waitForRemoval(albumID: String) async {
        let task = lock.withLock { removals[albumID] }
        await task?.value
    }
}
