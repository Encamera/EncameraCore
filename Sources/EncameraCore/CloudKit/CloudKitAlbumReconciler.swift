//
//  CloudKitAlbumReconciler.swift
//  EncameraCore
//
//  Makes CloudKit the authoritative, cross-device source of truth for which albums
//  exist. Two-way reconcile against the `EncAlbum` records in the zone, keyed by
//  the album's `albumID` (the record name):
//   - Pull: a remote album with no local `album.json` is adopted under its record
//     id (so it shows in the grid and gets its media reconciled); an album the
//     change feed reports deleted removes the local materialization, and one it
//     reports changed has its name, hidden flag and cover rewritten in place.
//   - Push: an album whose `album.json` is `dirty` holds a local change that has
//     not reached the record; it is saved, last writer wins, and then marked
//     clean. A local album that has NEVER been confirmed on the server is
//     uploaded too (self-heal), so an `EncAlbum` save that failed while offline
//     at create-time is recovered.
//
//  Deletions come from the zone change feed (`deletedAlbumIDs`), not from absence
//  in `fetchAllAlbums`. The reconciler does not read the feed itself:
//  `CloudKitSyncCoordinator` walks the zone once per sync for media and albums
//  alike and hands it the album part (`CloudKitAlbumChanges`). That distinction is the whole design: the query's index is
//  eventually consistent, so absence there is not evidence of anything, and a
//  reconciler that treated it as a delete would race every fresh create. An album
//  absent from the query that was never published is pushed (self-heal). One that
//  was published is looked up by id, which is strongly consistent: it is removed
//  locally only when that fetch finds no record, and left alone when the fetch
//  finds it or fails — no server-side tombstone required.
//
//  The album id is a minted UUID that says nothing about the album, so a fresh
//  device finds the album's key by decrypting the record's `encName` under each
//  synced key: the name is sealed with an authenticated secretstream, so only the
//  owning key opens it. Albums whose key is not present on this device (key backup
//  off) cannot be materialized and are reported via the locked-out count.
//
//  An album a whole-album move is still filling is not adopted: one this device's
//  plan names as its destination (`MigrationPlanStore.planRole`), or one whose
//  record another device flagged `migrationInProgress`. Adopting it would list a
//  half-filled second album beside the one being moved, and deleting that
//  "duplicate" would cascade to every record already moved. It is adopted on the
//  first pass after the move finalizes, or once the flag is abandoned: the device
//  that set it lost its plan, and neither the record nor the album's media has
//  changed for `CloudKitAlbumMembership.abandonedMoveFlagAge`. The flag is left on
//  the record; this device does not own the move, and every device applies the
//  same rule.
//
//  `.local` albums are never touched here — only CloudKit albums have `EncAlbum`
//  records, so a pure-local album never appears on another device.
//

import Foundation

/// How a `CloudKitAlbumReconciler.reconcileAlbums()` pass ended.
public enum CloudKitAlbumReconcileResult: Equatable, Sendable {
    /// The zone was read. `lockedOutCount` is the number of remote albums that
    /// could not be materialized for lack of a matching (synced) key;
    /// `storageFull` is whether an album save was refused because iCloud storage
    /// is full.
    case succeeded(lockedOutCount: Int, storageFull: Bool = false)
    /// No iCloud account is signed in or reachable; nothing was read.
    case accountUnavailable
    /// The album query failed, so this pass learned nothing about the server.
    case fetchFailed

    /// The locked-out count, or 0 when the pass never got that far.
    public var lockedOutCount: Int {
        if case .succeeded(let count, _) = self { return count }
        return 0
    }

    /// Whether an album save was refused because iCloud storage is full.
    public var storageFull: Bool {
        if case .succeeded(_, let storageFull) = self { return storageFull }
        return false
    }

    public var succeeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

public final class CloudKitAlbumReconciler: @unchecked Sendable, DebugPrintable {

    let store: CloudKitMediaStoring
    private let keyManager: KeyManager
    private let albumManager: AlbumManaging
    private let deleteQueue: CloudKitAlbumDeleteQueue
    private let publishRegistry: CloudKitAlbumPublishRegistry
    private let uploadQueue: CloudKitUploadQueue

    public init(store: CloudKitMediaStoring,
                keyManager: KeyManager,
                albumManager: AlbumManaging,
                deleteQueue: CloudKitAlbumDeleteQueue = CloudKitAlbumDeleteQueue(),
                publishRegistry: CloudKitAlbumPublishRegistry = CloudKitAlbumPublishRegistry(),
                uploadQueue: CloudKitUploadQueue = .shared) {
        self.store = store
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.deleteQueue = deleteQueue
        self.publishRegistry = publishRegistry
        self.uploadQueue = uploadQueue
    }

    /// Whether an iCloud account is available to reconcile against.
    public func accountAvailable() async -> Bool {
        await store.accountAvailable()
    }

    /// Reconcile album existence between CloudKit and the local filesystem markers.
    /// A successful pass carries the number of remote albums that could NOT be
    /// materialized for lack of a matching (synced) key — surfaced to the UI as
    /// "needs key backup".
    ///
    /// - Parameter changes: what the zone walk reported about albums since the
    ///   cursor. Deletions among them are applied before anything is pushed, so an
    ///   album deleted on another device is not uploaded again from here.
    @discardableResult
    public func reconcileAlbums(changes: CloudKitAlbumChanges) async -> CloudKitAlbumReconcileResult {
        printDebug("reconcileAlbums start")
        guard await store.accountAvailable() else {
            printDebug("reconcileAlbums skip reason=accountUnavailable")
            return .accountUnavailable
        }

        let pendingDeletes = await drainPendingDeletes()
        let deletedRemotely = applyRemoteAlbumChanges(changes)

        let remote: [CloudKitAlbumMetadata]
        do {
            remote = try await store.fetchAllAlbums()
            printDebug("reconcileAlbums fetchAllAlbums ok remoteCount=\(remote.count)")
        } catch {
            printDebug("reconcileAlbums fetchAllAlbums FAILED error=\(error)")
            return .fetchFailed
        }

        let keys = storedKeysOrEmpty()
        var onDeviceByID = localCloudKitAlbumsByID()
        printDebug("reconcileAlbums state keys=\(keys.count) localCloudKitAlbums=\(onDeviceByID.count) remote=\(remote.count)")
        for albumID in deletedRemotely { onDeviceByID[albumID] = nil }

        let pull = await pullRemoteAlbums(remote, onDeviceByID: onDeviceByID, pendingDeletes: pendingDeletes, keys: keys)
        let push = await pushAlbumsOnDeviceIfNeeded(onDeviceByID,
                                                    remoteIDs: Set(remote.map(\.albumID)),
                                                    pendingDeletes: pendingDeletes,
                                                    keys: keys)

        let deletedLocally = deletedRemotely.count + push.deleted
        printDebug("reconcileAlbums ok remote=\(remote.count) adopted=\(pull.adopted) deletedLocally=\(deletedLocally) pushed=\(push.pushed) lockedOut=\(pull.lockedOut) storageFull=\(push.storageFull) stillPendingDeletes=\(pendingDeletes.count)")
        return .succeeded(lockedOutCount: pull.lockedOut, storageFull: push.storageFull)
    }

    // MARK: - Delete drain

    /// Issues every queued local album delete and returns the ids still queued.
    ///
    /// Runs before the pull: a delete made offline or killed mid-flight must reach
    /// the server first, or its still-live record would resurrect the album on the
    /// very device that deleted it. Whatever fails to drain stays queued and is
    /// excluded from materialization and self-heal push this pass.
    private func drainPendingDeletes() async -> Set<String> {
        var pendingDeletes = deleteQueue.pending()
        printDebug("reconcileAlbums deleteDrain start pending=\(pendingDeletes.count)")
        for albumID in pendingDeletes.sorted() {
            switch await drainDecision(for: albumID) {
            case .delete:
                break
            case .keepQueued:
                continue
            case .abandon:
                deleteQueue.remove(albumID)
                pendingDeletes.remove(albumID)
                continue
            }
            do {
                try await store.deleteAlbum(albumID: albumID)
                deleteQueue.remove(albumID)
                publishRegistry.forget(albumID)
                pendingDeletes.remove(albumID)
                printDebug("reconcileAlbums deleteDrain ok albumID=\(albumID)")
            } catch {
                printDebug("reconcileAlbums deleteDrain FAILED albumID=\(albumID) error=\(error)")
            }
        }
        printDebug("reconcileAlbums deleteDrain done stillPending=\(pendingDeletes.count)")
        return pendingDeletes
    }

    private func storedKeysOrEmpty() -> [PrivateKey] {
        do {
            return try keyManager.storedKeys()
        } catch {
            printDebug("reconcileAlbums storedKeys FAILED error=\(error); proceeding with no keys")
            return []
        }
    }

    // MARK: - Pull

    private enum PullOutcome { case adopted, skipped, lockedOut }

    /// Adopts every remote album this device has not materialized and can open.
    private func pullRemoteAlbums(_ remote: [CloudKitAlbumMetadata],
                                  onDeviceByID: [String: Album],
                                  pendingDeletes: Set<String>,
                                  keys: [PrivateKey]) async -> (adopted: Int, lockedOut: Int) {
        var adopted = 0
        var lockedOut = 0
        for record in remote {
            switch await pull(record, onDeviceByID: onDeviceByID, pendingDeletes: pendingDeletes, keys: keys) {
            case .adopted: adopted += 1
            case .lockedOut: lockedOut += 1
            case .skipped: break
            }
        }
        return (adopted, lockedOut)
    }

    /// Adopts one remote album unless a delete of it is queued, it is already
    /// materialized, a move is still filling it, or no stored key opens its name.
    private func pull(_ record: CloudKitAlbumMetadata,
                      onDeviceByID: [String: Album],
                      pendingDeletes: Set<String>,
                      keys: [PrivateKey]) async -> PullOutcome {
        if pendingDeletes.contains(record.albumID) {
            printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=deletePending")
            return .skipped
        }

        publishRegistry.markPublished(record.albumID)

        if onDeviceByID[record.albumID] != nil {
            printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=alreadyMaterialized")
            return .skipped
        }

        if case .destination = MigrationPlanStore.planRole(forAlbumID: Self.cloudKitAlbumKey(record.albumID)) {
            printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=destinationOfALocalMove")
            return .skipped
        }
        if await CloudKitAlbumMembership.isBeingFilled(record, store: store) {
            printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=migrationInProgress")
            return .skipped
        }

        guard let match = Self.match(record: record, keys: keys) else {
            printDebug("reconcileAlbums pull MISS albumID=\(record.albumID) reason=noMatchingKey candidateKeys=\(keys.count)")
            //TODO: We have to surface this!
            return .lockedOut
        }
        printDebug("reconcileAlbums pull adopt albumID=\(record.albumID) isHidden=\(record.isHidden) createdAt=\(record.createdAt)")
        albumManager.adoptCloudKitAlbum(record: record, key: match.key)
        return .adopted
    }

    // MARK: - Push

    private enum PushDecision {
        case push(reason: String)
        case deleteLocally
        case skip
    }

    /// Pushes every CloudKit album on this device whose record lacks a change made
    /// here, and removes the ones whose published record is gone.
    private func pushAlbumsOnDeviceIfNeeded(_ onDeviceByID: [String: Album],
                                            remoteIDs: Set<String>,
                                            pendingDeletes: Set<String>,
                                            keys: [PrivateKey]) async -> (pushed: Int, deleted: Int, storageFull: Bool) {
        var pushed = 0
        var deleted = 0
        var storageFull = false
        for (albumID, album) in onDeviceByID where !pendingDeletes.contains(albumID) {
            let marker = CloudKitAlbumMarker.read(albumID: albumID)
            switch await pushDecision(for: albumID, marker: marker, remoteIDs: remoteIDs) {
            case .skip:
                continue
            case .deleteLocally:
                printDebug("reconcileAlbums delete albumID=\(albumID) reason=publishedAndNotFoundByID")
                albumManager.applyRemoteAlbumDeletion(album: album)
                publishRegistry.forget(albumID)
                deleted += 1
            case .push(let reason):
                switch await push(album: album, marker: marker, keys: keys, reason: reason) {
                case .pushed: pushed += 1
                case .storageFull: storageFull = true
                case .failed: break
                }
            }
        }
        return (pushed, deleted, storageFull)
    }

    /// Whether this device's copy of a CloudKit album is pushed to its record. One
    /// the query returned, or one found by id after the query missed it, is pushed
    /// only when its marker is dirty. One never published is pushed to self-heal a
    /// create-time save that failed. One published but not found by id was deleted
    /// elsewhere, so it is deleted here instead.
    private func pushDecision(for albumID: String,
                              marker: CloudKitAlbumMarker?,
                              remoteIDs: Set<String>) async -> PushDecision {
        let ifDirty: PushDecision = marker?.dirty == true ? .push(reason: "dirty") : .skip
        if remoteIDs.contains(albumID) {
            return ifDirty
        }
        guard publishRegistry.isPublished(albumID) else {
            return .push(reason: "neverPublished")
        }
        switch await lookUpByID(albumID) {
        case .present: return ifDirty
        case .gone: return .deleteLocally
        case .unknown: return .skip
        }
    }

    /// `Album.id` of the CloudKit album whose record name is `albumID`, the key
    /// `MigrationPlanStore.planRole(forAlbumID:)` takes.
    private static func cloudKitAlbumKey(_ albumID: String) -> String {
        "\(albumID)_\(StorageType.cloudKit.rawValue)"
    }

    private enum DrainDecision { case delete, keepQueued, abandon }

    /// Whether a queued album delete may be issued now. Every `EncMedia` parents to
    /// its album with `.deleteSelf`, so the delete takes every member with it.
    ///
    /// - An album a move on this device names (source or destination) keeps its
    ///   delete queued while it has members, and while the check cannot run.
    /// - An entry queued with `requiresNoMembers` (a move back to this device that
    ///   could not delete the emptied record) is dropped when the album has members
    ///   again: another device added them after the move, and they are not this
    ///   device's to delete. The album is then adopted like any other.
    /// - Any other queued delete is the user's, and goes ahead.
    private func drainDecision(for albumID: String) async -> DrainDecision {
        let role = MigrationPlanStore.planRole(forAlbumID: Self.cloudKitAlbumKey(albumID))
        let requiresNoMembers = deleteQueue.requiresNoMembers(albumID)
        guard role != .none || requiresNoMembers else { return .delete }
        let members: CloudKitAlbumMembers
        do {
            members = try await CloudKitAlbumMembership.members(ofAlbumID: albumID, store: store,
                                                                uploadQueue: uploadQueue)
        } catch {
            printDebug("reconcileAlbums deleteDrain keep albumID=\(albumID) reason=membershipCheckFailed error=\(error)")
            return .keepQueued
        }
        guard !members.isEmpty else { return .delete }
        if role != .none {
            printDebug("reconcileAlbums deleteDrain keep albumID=\(albumID) reason=moveInProgress records=\(members.records.count) queued=\(members.queuedUploads.count)")
            return .keepQueued
        }
        printDebug("reconcileAlbums deleteDrain ABANDON albumID=\(albumID) reason=albumHasMembers records=\(members.records.count) queued=\(members.queuedUploads.count)")
        return .abandon
    }

    private enum RecordLookup { case present, gone, unknown }

    /// Settles what a published album's absence from the query means. The query
    /// index lags a fresh save, so only a fetch by id, which is strongly
    /// consistent, can say the record is gone. A failed fetch says nothing.
    private func lookUpByID(_ albumID: String) async -> RecordLookup {
        do {
            if try await store.fetchAlbum(albumID: albumID) != nil {
                printDebug("reconcileAlbums keep albumID=\(albumID) reason=absentFromQueryButFoundByID")
                return .present
            }
            return .gone
        } catch {
            printDebug("reconcileAlbums keep albumID=\(albumID) reason=fetchByIDFailed error=\(error)")
            return .unknown
        }
    }

    private enum PushOutcome { case pushed, failed, storageFull }

    /// Saves the album's record and, on success, clears the marker's `dirty` flag
    /// unless the marker changed while the save was in flight. The name, creation
    /// date, hidden flag and cover come from `album.json` when there is one, so a
    /// pending local change is what reaches the record.
    private func push(album: Album, marker: CloudKitAlbumMarker?, keys: [PrivateKey], reason: String) async -> PushOutcome {
        guard let albumID = album.albumID else { return .failed }
        let pushed = marker.map {
            Album(encryptedName: $0.encName, storageOption: .cloudKit, creationDate: $0.createdAt,
                  key: album.key, albumID: albumID)
        } ?? album
        guard let albumFingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: pushed,
                                                                             keyManager: keyManager,
                                                                             storedKeysSnapshot: keys) else {
            printDebug("reconcileAlbums push skip albumID=\(albumID) reason=noKeyDecryptsTheName")
            return .failed
        }
        let upload = CloudKitAlbumUpload(albumID: albumID,
                                         encName: pushed.encryptedPathComponent,
                                         createdAt: pushed.creationDate,
                                         isHidden: marker?.isHidden ?? false,
                                         keyFingerprint: albumFingerprint,
                                         coverMediaID: marker?.recordCoverMediaID)
        printDebug("reconcileAlbums push start albumID=\(albumID) reason=\(reason) isHidden=\(upload.isHidden)")
        do {
            try await store.saveAlbum(upload)
        } catch {
            printDebug("reconcileAlbums push FAILED albumID=\(albumID) error=\(error)")
            if case .quotaExceeded = mapCKError(error) { return .storageFull }
            return .failed
        }
        publishRegistry.markPublished(albumID)
        if let marker {
            do {
                try CloudKitAlbumMarker.clearDirty(albumID: albumID, ifUnchangedFrom: marker)
            } catch {
                printDebug("reconcileAlbums clearDirty FAILED albumID=\(albumID) error=\(error)")
            }
        }
        printDebug("reconcileAlbums push ok albumID=\(albumID)")
        return .pushed
    }

    /// Applies what the zone change feed reported about albums and returns the ids
    /// removed. Deletions here are the authoritative cross-device delete signal.
    ///
    /// Local removal routes through `AlbumManager.applyRemoteAlbumDeletion` so
    /// observers get the broadcast, `currentAlbum` is fixed up, and synced-store /
    /// hidden-state entries are cleaned without touching CloudKit records.
    ///
    /// A changed album record rewrites the album's `album.json` in place when its
    /// name, hidden flag or cover differ — a remote rename changes no id, so nothing
    /// is deleted, adopted or evicted. A dirty marker keeps only the fields its local
    /// change touched; the push step saves those over the record.
    @discardableResult
    public func applyRemoteAlbumChanges(_ changes: CloudKitAlbumChanges) -> Set<String> {
        let onDeviceByID = localCloudKitAlbumsByID()
        let removed = applyRemoteAlbumDeletions(changes.deletedAlbumIDs, onDeviceByID: onDeviceByID)
        let metadataApplied = applyRemoteAlbumUpdates(changes.changedAlbums, onDeviceByID: onDeviceByID)

        if metadataApplied > 0 {
            albumManager.notifyAlbumsChanged()
        }
        printDebug("applyRemoteAlbumChanges ok removed=\(removed.count) metadataApplied=\(metadataApplied)")
        return removed
    }

    /// Removes each deleted album this device has materialized and returns the ids
    /// removed.
    private func applyRemoteAlbumDeletions(_ albumIDs: [String], onDeviceByID: [String: Album]) -> Set<String> {
        var removed: Set<String> = []
        for albumID in albumIDs {
            publishRegistry.forget(albumID)
            guard let album = onDeviceByID[albumID] else {
                printDebug("applyRemoteAlbumChanges skip albumID=\(albumID) reason=notMaterializedLocally")
                continue
            }
            printDebug("applyRemoteAlbumChanges delete albumID=\(albumID)")
            albumManager.applyRemoteAlbumDeletion(album: album)
            removed.insert(albumID)
        }
        return removed
    }

    /// Applies each changed album record to its `album.json` and returns how many
    /// were rewritten.
    private func applyRemoteAlbumUpdates(_ records: [CloudKitAlbumMetadata], onDeviceByID: [String: Album]) -> Int {
        var metadataApplied = 0
        for albumMeta in records {
            publishRegistry.markPublished(albumMeta.albumID)
            guard let coverChanged = applyRemoteMetadata(albumMeta) else { continue }
            metadataApplied += 1
            // album.json already holds the new cover, so a grid reload on this
            // event reads it.
            if coverChanged, onDeviceByID[albumMeta.albumID] != nil {
                FileOperationBus.shared.albumCoverChanged()
            }
        }
        return metadataApplied
    }

    /// Rewrites the album's `album.json` from `record` when the record's name,
    /// hidden flag or cover differ from it, and returns whether the cover changed.
    /// Returns nil when nothing was written: no marker on this device, or nothing
    /// changed. A dirty marker keeps the fields its pending local change touched,
    /// which the push step saves over the record, and takes the record's value for
    /// every other field, so that push does not revert another device's change. A
    /// record without a cover leaves a cover this device turned off as it is, since
    /// the record cannot carry that state.
    private func applyRemoteMetadata(_ record: CloudKitAlbumMetadata) -> Bool? {
        guard let marker = CloudKitAlbumMarker.read(albumID: record.albumID) else { return nil }
        let pending = marker.pendingFields
        if pending.count == CloudKitAlbumMarker.Field.allCases.count {
            printDebug("applyRemoteMetadata skip albumID=\(record.albumID) reason=dirty")
            return nil
        }
        let nameChanged = !pending.contains(.name) && marker.encName != record.encName
        let hiddenChanged = !pending.contains(.hidden) && marker.isHidden != record.isHidden
        let remoteCover = (record.coverMediaID == nil && marker.coverMediaID == CloudKitAlbumMarker.disabledCoverID)
            ? marker.coverMediaID
            : record.coverMediaID
        let coverChanged = !pending.contains(.cover) && marker.coverMediaID != remoteCover
        guard nameChanged || hiddenChanged || coverChanged else { return nil }
        var updated = marker
        if nameChanged || !marker.dirty {
            updated.encName = pending.contains(.name) ? marker.encName : record.encName
            updated.keyFingerprint = pending.contains(.name)
                ? marker.keyFingerprint
                : (record.keyFingerprint ?? marker.keyFingerprint)
        }
        if !marker.dirty { updated.createdAt = record.createdAt }
        if hiddenChanged { updated.isHidden = record.isHidden }
        if coverChanged { updated.coverMediaID = remoteCover }
        do {
            try updated.write(albumID: record.albumID)
        } catch {
            printDebug("applyRemoteMetadata write FAILED albumID=\(record.albumID) error=\(error)")
            return nil
        }
        printDebug("applyRemoteMetadata ok albumID=\(record.albumID) name=\(nameChanged) hidden=\(hiddenChanged) cover=\(coverChanged) keptPending=\(pending.map(\.rawValue).sorted())")
        return coverChanged
    }

    // MARK: - Matching

    /// Find the synced key that owns `record`: the first key, the record's
    /// fingerprint first, under which the album-name ciphertext decrypts. The name
    /// is sealed with an authenticated secretstream, so a wrong key fails its MAC
    /// and garbage ciphertext fails under every key. Pure + `internal` so it can be
    /// unit-tested directly.
    static func match(record: CloudKitAlbumMetadata, keys: [PrivateKey]) -> (name: String, key: PrivateKey)? {
        let ordered = record.keyFingerprint
            .flatMap { fingerprint in keys.first { $0.keyFingerprint == fingerprint } }
            .map { hinted in [hinted] + keys.filter { $0.keyFingerprint != hinted.keyFingerprint } }
            ?? keys
        for key in ordered {
            if let name = Album.decryptedAlbumName(record.encName, key: key) {
                printDebug("match hit albumID=\(record.albumID)")
                return (name, key)
            }
        }
        // Never log the decryption candidates themselves — the recovered name is
        // user data. Only the album id and the number of keys tried are safe.
        printDebug("match MISS albumID=\(record.albumID) keysTried=\(keys.count)")
        return nil
    }

    // MARK: - Local materialization

    private func localCloudKitAlbumsByID() -> [String: Album] {
        var byID: [String: Album] = [:]
        var unidentified = 0
        for album in albumManager.fetchAlbumsFromSources(includingHidden: true)
            where album.storageOption == .cloudKit {
            if let albumID = album.albumID {
                byID[albumID] = album
            } else {
                unidentified += 1
            }
        }
        if unidentified > 0 {
            printDebug("localCloudKitAlbumsByID WARNING albumsWithoutID=\(unidentified) identified=\(byID.count)")
        }
        printDebug("localCloudKitAlbumsByID ok count=\(byID.count)")
        return byID
    }

}
