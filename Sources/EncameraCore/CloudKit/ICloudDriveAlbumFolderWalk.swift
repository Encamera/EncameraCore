//
//  ICloudDriveAlbumFolderWalk.swift
//  EncameraCore
//
//  The walk over this device's iCloud Drive album folders. Each folder's marker
//  file (`ICloudDriveAlbumMarkerFile`) says whether the folder belongs to a
//  CloudKit album; the walk classifies every folder by it and acts on the result:
//
//  - A folder whose marker names a CloudKit album this device has adopted is that
//    album's iCloud Drive half. It is not listed as an album of its own, and the
//    album's `album.json` links to it.
//  - A folder whose marker names an album this device has not adopted yet has
//    its `EncAlbum` fetched by id, which is strongly consistent where the album
//    query is not. A record found is adopted with the link to the folder in one
//    `album.json` write, which is also what switches the album list from the
//    folder to the CloudKit album.
//  - A marker with conflicting versions (two devices migrated the folder at
//    once, each saving its own `EncAlbum`) keeps the version whose record sorts
//    first by `CloudKitAlbumMetadata.precedes`, so every device lands on the same
//    album. The walk writes that version as the marker, resolves the conflict
//    and handles the folder as above. It then deletes each losing `EncAlbum` that
//    a fresh membership check finds empty, and this device's iCloud Drive
//    migration plan into it; one holding media is left alone. The migration
//    (`ICloudDriveAlbumMigration`) follows the marker on its next run.
//  - A folder whose marker names an album deleted on this device
//    (`DeletedCloudKitAlbums`) is not adopted and not listed; the album's
//    delete, or the next `ICloudDriveAlbumMigration.runEveryFolder()`, removes it
//    (`ICloudDriveAlbumDeletion`).
//  - Every other folder is listed as a plain iCloud Drive album: no marker, an
//    evicted marker (whose download is requested), a record confirmed gone, a
//    record not visible yet, or a marker that cannot be used as it is.
//
//  The link from an adopted album to its folder follows the marker file, not the
//  folder's name: a folder an older build renamed is re-linked when the walk
//  finds its marker. A link whose folder is nowhere to be found is left as it is.
//
//  Nothing here deletes or renames a folder or anything in it except the marker's
//  own conflict versions. Absence of a record is never proof the folder should
//  go: another device may still be saving it, or its own folder delete may not
//  have synced yet.
//
//  The album list itself (`AlbumManager.fetchAlbumsFromSources`) applies the
//  same classification without fetching, so a folder disappears from the list
//  exactly when the CloudKit album it names appears in it.
//

import Foundation

/// What a fetch of a marker's `EncAlbum` by id found.
public enum ICloudDriveAlbumRecordLookup: Equatable, Sendable {
    /// No fetch was made.
    case notFetched
    case found(CloudKitAlbumMetadata)
    /// The server has no record with the id.
    case notFound
    /// The fetch failed or no account was available. Says nothing about the record.
    case failed
}

/// Where an iCloud Drive album folder stands on joining the CloudKit album its
/// marker names.
public enum ICloudDriveAlbumAdoptionState: Equatable, Sendable {
    /// No marker: a plain iCloud Drive album, listed as one.
    case noMarker
    /// The marker names a CloudKit album this device has adopted. The folder holds
    /// that album's media not yet in CloudKit and is not listed on its own.
    case adopted(albumID: String)
    /// The marker names an album this device has not adopted and its record has
    /// not been fetched yet. Listed as a plain iCloud Drive album.
    case needsFetch(albumID: String)
    /// The marker's record was fetched and can be adopted. Listed as a plain
    /// iCloud Drive album until the adoption is written.
    case adoptable(CloudKitAlbumMetadata)
    /// Only the marker's iCloud placeholder is on this device. Listed as a plain
    /// iCloud Drive album until it downloads.
    case markerEvicted
    /// The marker names a record this device saw published that a fetch by id no
    /// longer finds: it was deleted elsewhere. Listed as a plain iCloud Drive album.
    case recordGone(albumID: String)
    /// The marker names a record a fetch by id does not find and this device never
    /// saw published: it may still be on its way. Listed as a plain iCloud Drive
    /// album and checked again on the next walk.
    case recordNotVisibleYet(albumID: String)
    /// The fetch by id failed. Listed as a plain iCloud Drive album and checked
    /// again on the next walk.
    case lookupFailed(albumID: String)
    /// This device deleted the album: the delete has not reached the server, or
    /// the album is in `DeletedCloudKitAlbums`. Its record is not adopted again.
    /// The album list leaves out a folder whose album is in `DeletedCloudKitAlbums`
    /// and `ICloudDriveAlbumDeletion` removes it; any other is listed as a plain
    /// iCloud Drive album.
    case deletePending(albumID: String)
    /// The marker has unresolved conflict versions this walk could not resolve
    /// (see `ICloudDriveAlbumAdoptionState.resolveConflict`). Listed as a plain
    /// iCloud Drive album; nothing is adopted from it.
    case markerConflicted([ICloudDriveAlbumMarkerFile])
    /// The marker does not decode, or is in a format newer than this build reads.
    /// Listed as a plain iCloud Drive album.
    case markerUnreadable

    /// Whether the folder shows in the album list as an iCloud Drive album.
    public var listsFolderAsPlainAlbum: Bool {
        if case .adopted = self { return false }
        return true
    }

    /// The album id the marker names, when it was read.
    public var albumID: String? {
        switch self {
        case .adopted(let albumID), .needsFetch(let albumID), .recordGone(let albumID),
             .recordNotVisibleYet(let albumID), .lookupFailed(let albumID), .deletePending(let albumID):
            return albumID
        case .adoptable(let record):
            return record.albumID
        case .noMarker, .markerEvicted, .markerConflicted, .markerUnreadable:
            return nil
        }
    }
}

extension ICloudDriveAlbumAdoptionState {

    /// The adoption state of one iCloud Drive album folder. Pure.
    ///
    /// - Parameters:
    ///   - marker: the folder's marker file as read.
    ///   - isAdopted: whether this device has adopted the CloudKit album with an id.
    ///   - isDeletePending: whether this device has a delete of the album queued.
    ///   - lookup: what fetching the marker's record by id found.
    ///   - isPublished: whether this device has seen the album confirmed on the
    ///     server (`CloudKitAlbumPublishRegistry`).
    public static func classify(marker: ICloudDriveAlbumMarkerFile.ReadResult,
                                isAdopted: (String) -> Bool,
                                isDeletePending: (String) -> Bool = { _ in false },
                                lookup: ICloudDriveAlbumRecordLookup = .notFetched,
                                isPublished: (String) -> Bool = { _ in false }) -> ICloudDriveAlbumAdoptionState {
        let albumID: String
        switch marker {
        case .absent: return .noMarker
        case .evicted: return .markerEvicted
        case .unreadable: return .markerUnreadable
        case .conflicted(let versions): return .markerConflicted(versions)
        case .present(let file): albumID = file.albumID
        }
        if isAdopted(albumID) { return .adopted(albumID: albumID) }
        if isDeletePending(albumID) { return .deletePending(albumID: albumID) }
        switch lookup {
        case .notFetched:
            return .needsFetch(albumID: albumID)
        case .found(let record) where record.albumID == albumID:
            return .adoptable(record)
        case .found, .notFound:
            return isPublished(albumID) ? .recordGone(albumID: albumID) : .recordNotVisibleYet(albumID: albumID)
        case .failed:
            return .lookupFailed(albumID: albumID)
        }
    }
}

/// Which album the conflicting versions of a marker resolve to.
public enum ICloudDriveAlbumMarkerConflictResolution: Equatable, Sendable {
    /// Keep the version naming `winner`. `losers` are the other versions' records
    /// that the server still has.
    case keep(winner: CloudKitAlbumMetadata, losers: [CloudKitAlbumMetadata])
    /// Not resolved on this walk: a version's record could not be fetched, may
    /// still be on its way, or none of the records is left.
    case unresolved
}

extension ICloudDriveAlbumAdoptionState {

    /// Picks the album the conflicting versions of a marker resolve to. Pure.
    ///
    /// A version whose record the server no longer has and that this device saw
    /// published is out of the running. Any other version whose record is not in
    /// hand (the fetch failed, was not made, or found nothing for an album never
    /// seen published) leaves the conflict unresolved, so the walk tries again
    /// later rather than choosing from part of the candidates. Of the records in
    /// hand, the one `CloudKitAlbumMetadata.precedes` puts first wins.
    ///
    /// - Parameters:
    ///   - lookups: what fetching each version's album id found.
    ///   - isPublished: whether this device has seen the album confirmed on the server.
    public static func resolveConflict(lookups: [String: ICloudDriveAlbumRecordLookup],
                                       isPublished: (String) -> Bool) -> ICloudDriveAlbumMarkerConflictResolution {
        var records: [CloudKitAlbumMetadata] = []
        for (albumID, lookup) in lookups {
            switch lookup {
            case .found(let record) where record.albumID == albumID:
                records.append(record)
            case .found, .notFound:
                guard isPublished(albumID) else { return .unresolved }
            case .notFetched, .failed:
                return .unresolved
            }
        }
        let ordered = records.sorted(by: CloudKitAlbumMetadata.precedes)
        guard let winner = ordered.first else { return .unresolved }
        return .keep(winner: winner, losers: Array(ordered.dropFirst()))
    }
}

/// Walks every iCloud Drive album folder on this device, adopting the CloudKit
/// albums their markers name and linking each adopted album to its folder.
public final class ICloudDriveAlbumFolderWalk: @unchecked Sendable, DebugPrintable {

    public struct FolderResult: Equatable, Sendable {
        public let folder: URL
        public let adoptionState: ICloudDriveAlbumAdoptionState
        /// Whether this walk adopted the album or wrote the folder link.
        public let changedAlbumMarker: Bool
    }

    private let albumManager: AlbumManaging
    private let makeStore: @Sendable () -> CloudKitMediaStoring
    private let publishRegistry: CloudKitAlbumPublishRegistry
    private let deleteQueue: CloudKitAlbumDeleteQueue
    private let requestMarkerDownload: @Sendable (URL) -> Void
    private let conflictVersions: @Sendable (URL) -> [URL]
    private let resolveMarkerConflict: @Sendable (URL, ICloudDriveAlbumMarkerFile) throws -> Void
    private let uploadQueue: CloudKitUploadQueue
    private let flipRegistry: ICloudDriveAlbumFlipRegistry
    private let deletedAlbums: DeletedCloudKitAlbums
    private var store: CloudKitMediaStoring?

    /// - Parameters:
    ///   - makeStore: builds the CloudKit store, only once a folder needs a fetch.
    ///   - requestMarkerDownload: asks iCloud to download an evicted marker, given
    ///     the marker's materialized URL.
    ///   - conflictVersions: the unresolved conflict versions of a marker file.
    ///   - resolveMarkerConflict: writes the given marker as the current version of
    ///     the marker file at the URL and resolves and removes its other versions.
    ///   - uploadQueue: this device's pending uploads, which count as members of a
    ///     losing album.
    ///   - flipRegistry: the albums an iCloud Drive album migration run will flip
    ///     itself, which the walk does not adopt.
    ///   - deletedAlbums: the albums deleted on this device, which the walk does
    ///     not adopt again.
    public init(albumManager: AlbumManaging,
                makeStore: @escaping @Sendable () -> CloudKitMediaStoring,
                publishRegistry: CloudKitAlbumPublishRegistry = CloudKitAlbumPublishRegistry(),
                deleteQueue: CloudKitAlbumDeleteQueue = CloudKitAlbumDeleteQueue(),
                requestMarkerDownload: @escaping @Sendable (URL) -> Void = { ICloudDriveAlbumFolderWalk.requestDownload(ofMarker: $0) },
                conflictVersions: @escaping @Sendable (URL) -> [URL] = { ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of: $0) },
                resolveMarkerConflict: @escaping @Sendable (URL, ICloudDriveAlbumMarkerFile) throws -> Void = { try ICloudDriveAlbumMarkerFile.resolveConflict(at: $0, keeping: $1) },
                uploadQueue: CloudKitUploadQueue = .shared,
                flipRegistry: ICloudDriveAlbumFlipRegistry = .shared,
                deletedAlbums: DeletedCloudKitAlbums = DeletedCloudKitAlbums()) {
        self.albumManager = albumManager
        self.makeStore = makeStore
        self.publishRegistry = publishRegistry
        self.deleteQueue = deleteQueue
        self.requestMarkerDownload = requestMarkerDownload
        self.conflictVersions = conflictVersions
        self.resolveMarkerConflict = resolveMarkerConflict
        self.uploadQueue = uploadQueue
        self.flipRegistry = flipRegistry
        self.deletedAlbums = deletedAlbums
    }

    /// Requests the download of an evicted marker through the same path the
    /// migration's materializer uses.
    public static func requestDownload(ofMarker markerURL: URL) {
        do {
            try ICloudDriveMaterializer.requestDownload(of: markerURL)
        } catch {
            printDebug("requestDownload FAILED marker=\(markerURL.lastPathComponent) error=\(error)")
        }
    }

    /// The iCloud Drive album folders on this device, or none when iCloud Drive is
    /// unavailable.
    static func albumFolders() -> [URL] {
        guard DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) == .available else { return [] }
        return iCloudStorageModel.enumerateAlbumsDirectory()
    }

    /// Walks every folder and broadcasts the album list once if any album was
    /// adopted or linked.
    @discardableResult
    public func run() async -> [FolderResult] {
        let folders = Self.albumFolders()
        var results: [FolderResult] = []
        for folder in folders {
            results.append(await walk(folder: folder))
        }
        let changed = results.filter(\.changedAlbumMarker).count
        if changed > 0 {
            albumManager.notifyAlbumsChanged()
        }
        printDebug("run ok folders=\(folders.count) changed=\(changed)")
        return results
    }

    /// Finds one folder's adoption state and acts on it. A conflicted marker is resolved
    /// first, and the folder is then handled by the version kept.
    func walk(folder: URL) async -> FolderResult {
        var marker = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder, conflictVersions: conflictVersions)
        var knownLookup = ICloudDriveAlbumRecordLookup.notFetched
        var losers: [CloudKitAlbumMetadata] = []
        if case .conflicted(let versions) = marker,
           let resolved = await resolveConflict(versions, folder: folder) {
            marker = .present(resolved.kept)
            knownLookup = resolved.keptLookup
            losers = resolved.losers
        }
        var adoptionState = classify(marker, lookup: knownLookup)
        if case .needsFetch(let albumID) = adoptionState {
            adoptionState = classify(marker, lookup: await lookUp(albumID))
        }

        var changed = false
        switch adoptionState {
        case .adopted(let albumID):
            changed = link(albumID: albumID, to: folder)
        case .adoptable(let record):
            changed = adopt(record, folder: folder)
        case .markerEvicted:
            requestMarkerDownload(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder))
        case .noMarker, .needsFetch, .recordGone, .recordNotVisibleYet, .lookupFailed,
             .deletePending, .markerConflicted, .markerUnreadable:
            break
        }
        for loser in losers where await deleteLosingAlbumIfEmpty(loser.albumID) {
            changed = true
        }
        printDebug("walk folder state=\(Self.logName(adoptionState)) albumID=\(adoptionState.albumID ?? "-") changed=\(changed)")
        return FolderResult(folder: folder, adoptionState: adoptionState, changedAlbumMarker: changed)
    }

    private func classify(_ marker: ICloudDriveAlbumMarkerFile.ReadResult,
                          lookup: ICloudDriveAlbumRecordLookup) -> ICloudDriveAlbumAdoptionState {
        ICloudDriveAlbumAdoptionState.classify(marker: marker,
                                               isAdopted: { CloudKitAlbumMarker.exists(albumID: $0) },
                                               isDeletePending: { [deleteQueue, deletedAlbums] in
                                                   deleteQueue.pending().contains($0) || deletedAlbums.contains($0)
                                               },
                                               lookup: lookup,
                                               isPublished: { [publishRegistry] in publishRegistry.isPublished($0) })
    }

    private func currentStore() -> CloudKitMediaStoring {
        let store = self.store ?? makeStore()
        self.store = store
        return store
    }

    private func lookUp(_ albumID: String) async -> ICloudDriveAlbumRecordLookup {
        let store = currentStore()
        guard await store.accountAvailable() else { return .failed }
        do {
            guard let record = try await store.fetchAlbum(albumID: albumID) else { return .notFound }
            return .found(record)
        } catch {
            printDebug("lookUp FAILED albumID=\(albumID) error=\(error)")
            return .failed
        }
    }

    // MARK: - Conflicting marker versions

    private struct ResolvedConflict {
        let kept: ICloudDriveAlbumMarkerFile
        /// What is already known of the kept version's record.
        let keptLookup: ICloudDriveAlbumRecordLookup
        let losers: [CloudKitAlbumMetadata]
    }

    /// Picks the version to keep, writes it as the marker's current version and
    /// resolves the conflict. Nil, changing nothing, when the conflict cannot be
    /// resolved on this walk.
    private func resolveConflict(_ versions: [ICloudDriveAlbumMarkerFile], folder: URL) async -> ResolvedConflict? {
        var albumIDs: [String] = []
        for version in versions where !albumIDs.contains(version.albumID) {
            albumIDs.append(version.albumID)
        }
        let keptAlbumID: String
        var keptLookup = ICloudDriveAlbumRecordLookup.notFetched
        var losers: [CloudKitAlbumMetadata] = []
        if albumIDs.count == 1 {
            keptAlbumID = albumIDs[0]
        } else {
            var lookups: [String: ICloudDriveAlbumRecordLookup] = [:]
            for albumID in albumIDs {
                lookups[albumID] = await lookUp(albumID)
            }
            let resolution = ICloudDriveAlbumAdoptionState.resolveConflict(
                lookups: lookups,
                isPublished: { [publishRegistry] in publishRegistry.isPublished($0) })
            guard case .keep(let winner, let losing) = resolution else {
                printDebug("resolveConflict skip versions=\(versions.count) reason=unresolved")
                return nil
            }
            keptAlbumID = winner.albumID
            keptLookup = .found(winner)
            losers = losing
        }
        guard let kept = versions.first(where: { $0.albumID == keptAlbumID }) else { return nil }

        do {
            try resolveMarkerConflict(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder), kept)
        } catch {
            printDebug("resolveConflict FAILED albumID=\(keptAlbumID) error=\(error)")
            return nil
        }
        printDebug("resolveConflict ok kept=\(keptAlbumID) versions=\(versions.count) losers=\(losers.map(\.albumID))")
        return ResolvedConflict(kept: kept, keptLookup: keptLookup, losers: losers)
    }

    /// Deletes the losing album's record when a fresh membership check, made right
    /// before the delete, finds no media in it and none queued for it here, with
    /// any iCloud Drive migration plan this device holds for it. An album holding
    /// media is left for the user. The delete is queued first, so
    /// one that fails is retried by the album reconciler, which checks membership
    /// again before issuing it; so is one whose membership check fails here.
    ///
    /// - Returns: whether this device's copy of the album was removed.
    private func deleteLosingAlbumIfEmpty(_ albumID: String) async -> Bool {
        let store = currentStore()
        let members: CloudKitAlbumMembers
        do {
            members = try await CloudKitAlbumMembership.members(ofAlbumID: albumID, store: store,
                                                                uploadQueue: uploadQueue)
        } catch {
            printDebug("deleteLosingAlbum deferred albumID=\(albumID) reason=membershipCheckFailed error=\(error)")
            deleteQueue.enqueue(albumID, requiresNoMembers: true)
            return false
        }
        guard members.isEmpty else {
            printDebug("deleteLosingAlbum keep albumID=\(albumID) records=\(members.records.count) queued=\(members.queuedUploads.count)")
            return false
        }
        deleteQueue.enqueue(albumID, requiresNoMembers: true)
        do {
            try await store.deleteAlbum(albumID: albumID)
        } catch {
            printDebug("deleteLosingAlbum deferred albumID=\(albumID) reason=deleteFailed error=\(error)")
            return false
        }
        deleteQueue.remove(albumID)
        publishRegistry.forget(albumID)
        MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        printDebug("deleteLosingAlbum ok albumID=\(albumID)")
        return removeLocalCopy(ofAlbumID: albumID)
    }

    /// Removes what this device holds for a deleted CloudKit album, as a delete
    /// arriving from another device would. Its iCloud Drive folder is untouched.
    private func removeLocalCopy(ofAlbumID albumID: String) -> Bool {
        guard CloudKitAlbumMarker.exists(albumID: albumID) else { return false }
        if let album = albumManager.cloudKitAlbum(withID: albumID) {
            albumManager.applyRemoteAlbumDeletion(album: album)
        } else {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        return true
    }

    /// Adopts the record with its link to `folder`, in one `album.json` write. A
    /// record no stored key opens is left unadopted, and the folder stays listed.
    /// So is one an iCloud Drive album migration run holds: the run adopts it once
    /// the album's index is built.
    private func adopt(_ record: CloudKitAlbumMetadata, folder: URL) -> Bool {
        publishRegistry.markConfirmedOnServer(record.albumID)
        guard !CloudKitAlbumMarker.exists(albumID: record.albumID) else {
            return link(albumID: record.albumID, to: folder)
        }
        guard !flipRegistry.isHeld(record.albumID) else {
            printDebug("adopt skip albumID=\(record.albumID) reason=migrationFlipsIt")
            return false
        }
        let keys = (try? albumManager.keyManager.storedKeys()) ?? []
        guard let match = CloudKitAlbumReconciler.match(record: record, keys: keys) else {
            printDebug("adopt skip albumID=\(record.albumID) reason=noMatchingKey candidateKeys=\(keys.count)")
            return false
        }
        albumManager.adoptCloudKitAlbum(record: record, key: match.key, linkingICloudDriveFolder: folder)
        return CloudKitAlbumMarker.exists(albumID: record.albumID)
    }

    /// Links the adopted album `albumID` to `folder`, whose marker names it. A link
    /// to another folder is replaced only when that folder no longer holds a marker
    /// naming the album, as when an older build renamed or removed it; a folder
    /// that still does keeps the link. Nothing here removes a link.
    private func link(albumID: String, to folder: URL) -> Bool {
        if let linked = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID),
           CloudKitAlbumMarker.iCloudDriveFolderPath(for: linked) != CloudKitAlbumMarker.iCloudDriveFolderPath(for: folder),
           case .present(let linkedMarker) = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: linked,
                                                                              conflictVersions: conflictVersions),
           linkedMarker.albumID == albumID {
            printDebug("link keep albumID=\(albumID) reason=linkedFolderStillHoldsMarker")
            return false
        }
        do {
            return try CloudKitAlbumMarker.linkICloudDriveFolder(folder, albumID: albumID)
        } catch {
            printDebug("link FAILED albumID=\(albumID) error=\(error)")
            return false
        }
    }

    /// The case name only: folder names can be plaintext album names.
    private static func logName(_ adoptionState: ICloudDriveAlbumAdoptionState) -> String {
        switch adoptionState {
        case .noMarker: return "noMarker"
        case .adopted: return "adopted"
        case .needsFetch: return "needsFetch"
        case .adoptable: return "adoptable"
        case .markerEvicted: return "markerEvicted"
        case .recordGone: return "recordGone"
        case .recordNotVisibleYet: return "recordNotVisibleYet"
        case .lookupFailed: return "lookupFailed"
        case .deletePending: return "deletePending"
        case .markerConflicted: return "markerConflicted"
        case .markerUnreadable: return "markerUnreadable"
        }
    }
}
