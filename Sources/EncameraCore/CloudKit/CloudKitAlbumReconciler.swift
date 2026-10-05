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
//  in `fetchAllAlbums`. That distinction is the whole design: the query's index is
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
//  first pass after the move finalizes.
//
//  `.local` albums are never touched here — only CloudKit albums have `EncAlbum`
//  records, so a pure-local album never appears on another device.
//

import Foundation

public final class CloudKitAlbumReconciler: @unchecked Sendable, DebugPrintable {

    private let store: CloudKitMediaStoring
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

    /// Reconcile album existence between CloudKit and the local filesystem markers.
    /// Returns the number of remote albums that could NOT be materialized for lack of
    /// a matching (synced) key — surfaced to the UI as "needs key backup".
    @discardableResult
    public func reconcileAlbums() async -> Int {
        printDebug("reconcileAlbums start")
        guard await store.accountAvailable() else {
            printDebug("reconcileAlbums skip reason=accountUnavailable")
            return 0
        }

        // 0. Drain pending local delete intents FIRST: a delete made offline or
        // killed mid-flight must reach the server before the pull below, or its
        // still-live record would resurrect the album on the very device that
        // deleted it. Whatever fails to drain stays queued and is excluded from
        // materialization and self-heal push this pass.
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

        let deletedRemotely = await applyRemoteDeletions()

        let remote: [CloudKitAlbumMetadata]
        do {
            remote = try await store.fetchAllAlbums()
            printDebug("reconcileAlbums fetchAllAlbums ok remoteCount=\(remote.count)")
        } catch {
            printDebug("reconcileAlbums fetchAllAlbums FAILED error=\(error)")
            return 0
        }

        let keys: [PrivateKey]
        do {
            keys = try keyManager.storedKeys()
        } catch {
            printDebug("reconcileAlbums storedKeys FAILED error=\(error); proceeding with no keys")
            keys = []
        }
        var localByID = localCloudKitAlbumsByID()
        var remoteIDs = Set<String>()
        var lockedOut = 0
        var adopted = 0
        printDebug("reconcileAlbums state keys=\(keys.count) localCloudKitAlbums=\(localByID.count) remote=\(remote.count)")
        for albumID in deletedRemotely { localByID[albumID] = nil }

        for record in remote {
            remoteIDs.insert(record.albumID)

            if pendingDeletes.contains(record.albumID) {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=deletePending")
                continue
            }

            publishRegistry.markPublished(record.albumID)

            if localByID[record.albumID] != nil {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=alreadyMaterialized")
                continue
            }

            if case .destination = MigrationPlanStore.planRole(forAlbumID: Self.cloudKitAlbumKey(record.albumID)) {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=destinationOfALocalMove")
                continue
            }
            if record.migrationInProgress {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=migrationInProgress")
                continue
            }

            guard let match = Self.match(record: record, keys: keys) else {
                lockedOut += 1
                printDebug("reconcileAlbums pull MISS albumID=\(record.albumID) reason=noMatchingKey candidateKeys=\(keys.count)")
                //TODO: We have to surface this!
                continue
            }
            printDebug("reconcileAlbums pull adopt albumID=\(record.albumID) isHidden=\(record.isHidden) createdAt=\(record.createdAt)")
            albumManager.adoptCloudKitAlbum(record: record, key: match.key)
            if let coverID = record.coverMediaID {
                let adoptedAlbum = Album(encryptedName: record.encName, storageOption: .cloudKit,
                                         creationDate: record.createdAt, key: match.key, albumID: record.albumID)
                let sidecar = AlbumCoverSidecar(album: adoptedAlbum)
                Task { try? await sidecar.setCoverMediaID(coverID) }
            }
            adopted += 1
        }

        var pushed = 0
        var deletedLocally = deletedRemotely.count
        for (albumID, album) in localByID where !pendingDeletes.contains(albumID) {
            let marker = CloudKitAlbumMarker.read(albumID: albumID)
            let reason: String
            if remoteIDs.contains(albumID) {
                guard marker?.dirty == true else { continue }
                reason = "dirty"
            } else if publishRegistry.isPublished(albumID) {
                switch await lookUpByID(albumID) {
                case .present:
                    guard marker?.dirty == true else { continue }
                    reason = "dirty"
                case .gone:
                    printDebug("reconcileAlbums delete albumID=\(albumID) reason=publishedAndNotFoundByID")
                    albumManager.applyRemoteAlbumDeletion(album: album)
                    publishRegistry.forget(albumID)
                    deletedLocally += 1
                    continue
                case .unknown:
                    continue
                }
            } else {
                reason = "neverPublished"
            }

            if await push(album: album, marker: marker, keys: keys, reason: reason) {
                pushed += 1
            }
        }

        printDebug("reconcileAlbums ok remote=\(remote.count) adopted=\(adopted) deletedLocally=\(deletedLocally) pushed=\(pushed) lockedOut=\(lockedOut) stillPendingDeletes=\(pendingDeletes.count)")
        return lockedOut
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

    /// Saves the album's record and, on success, clears the marker's `dirty` flag
    /// unless the marker changed while the save was in flight. The name, creation
    /// date, hidden flag and cover come from `album.json` when there is one, so a
    /// pending local change is what reaches the record.
    private func push(album: Album, marker: CloudKitAlbumMarker?, keys: [PrivateKey], reason: String) async -> Bool {
        guard let albumID = album.albumID else { return false }
        let pushed = marker.map {
            Album(encryptedName: $0.encName, storageOption: .cloudKit, creationDate: $0.createdAt,
                  key: album.key, albumID: albumID)
        } ?? album
        guard let albumFingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: pushed,
                                                                             keyManager: keyManager,
                                                                             storedKeysSnapshot: keys) else {
            printDebug("reconcileAlbums push skip albumID=\(albumID) reason=noKeyDecryptsTheName")
            return false
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
            return false
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
        return true
    }

    /// Applies what the zone change feed reports about albums and returns the ids
    /// removed. Deletions here are the authoritative cross-device delete signal.
    ///
    /// Local removal routes through `AlbumManager.applyRemoteAlbumDeletion` so
    /// observers get the broadcast, `currentAlbum` is fixed up, and synced-store /
    /// hidden-state entries are cleaned without touching CloudKit records.
    ///
    /// A changed album record rewrites the album's `album.json` in place when its
    /// name, hidden flag or cover differ — a remote rename changes no id, so nothing
    /// is deleted, adopted or evicted. A dirty marker is left alone: it holds a local
    /// change the push step saves over the record.
    private func applyRemoteDeletions() async -> Set<String> {
        var removed: Set<String> = []
        var metadataApplied = 0
        let localByID = localCloudKitAlbumsByID()
        var token = await store.loadChangeToken()
        var moreComing = true

        while moreComing {
            let changeSet: CloudKitChangeSet
            do {
                changeSet = try await store.fetchChanges(since: token)
            } catch {
                printDebug("applyRemoteDeletions fetchChanges FAILED error=\(error)")
                return removed
            }
            if changeSet.token != nil { token = changeSet.token }
            moreComing = changeSet.moreComing

            for albumID in changeSet.deletedAlbumIDs {
                publishRegistry.forget(albumID)
                guard let album = localByID[albumID] else {
                    printDebug("applyRemoteDeletions skip albumID=\(albumID) reason=notMaterializedLocally")
                    continue
                }
                printDebug("applyRemoteDeletions delete albumID=\(albumID)")
                albumManager.applyRemoteAlbumDeletion(album: album)
                removed.insert(albumID)
            }
            for albumMeta in changeSet.changedAlbums {
                publishRegistry.markPublished(albumMeta.albumID)
                let localAlbum = localByID[albumMeta.albumID]
                var coverApplied = false
                if let coverChanged = applyRemoteMetadata(albumMeta) {
                    metadataApplied += 1
                    if coverChanged, let localAlbum {
                        let sidecar = AlbumCoverSidecar(album: localAlbum)
                        Task { try? await sidecar.setCoverMediaID(albumMeta.coverMediaID) }
                        coverApplied = true
                    }
                }
                if let localAlbum {
                    if !coverApplied, albumManager.getAlbumCoverImageId(album: localAlbum) == nil {
                        let sidecar = AlbumCoverSidecar(album: localAlbum)
                        Task { try? await sidecar.setCoverMediaID(albumMeta.coverMediaID) }
                    }
                    FileOperationBus.shared.albumCoverChanged()
                }
            }
        }

        // Committed only after the deletions above were applied, so a failure
        // re-reads the same notices rather than losing them.
        await store.commitChangeToken(token)
        if metadataApplied > 0 {
            albumManager.notifyAlbumsChanged()
        }
        printDebug("applyRemoteDeletions ok removed=\(removed.count) metadataApplied=\(metadataApplied)")
        return removed
    }

    /// Rewrites the album's `album.json` from `record` when the record's name,
    /// hidden flag or cover differ from it, and returns whether the cover changed.
    /// Returns nil when nothing was written: no marker on this device, a dirty
    /// marker, or nothing changed. A record without a cover leaves a cover this
    /// device turned off as it is, since the record cannot carry that state.
    private func applyRemoteMetadata(_ record: CloudKitAlbumMetadata) -> Bool? {
        guard let marker = CloudKitAlbumMarker.read(albumID: record.albumID) else { return nil }
        if marker.dirty {
            printDebug("applyRemoteMetadata skip albumID=\(record.albumID) reason=dirty")
            return nil
        }
        let nameChanged = marker.encName != record.encName
        let hiddenChanged = marker.isHidden != record.isHidden
        let remoteCover = (record.coverMediaID == nil && marker.coverMediaID == CloudKitAlbumMarker.disabledCoverID)
            ? marker.coverMediaID
            : record.coverMediaID
        let coverChanged = marker.coverMediaID != remoteCover
        guard nameChanged || hiddenChanged || coverChanged else { return nil }
        let updated = CloudKitAlbumMarker(encName: record.encName,
                                          createdAt: record.createdAt,
                                          isHidden: record.isHidden,
                                          coverMediaID: remoteCover,
                                          keyFingerprint: record.keyFingerprint ?? marker.keyFingerprint,
                                          dirty: false)
        do {
            try updated.write(albumID: record.albumID)
        } catch {
            printDebug("applyRemoteMetadata write FAILED albumID=\(record.albumID) error=\(error)")
            return nil
        }
        printDebug("applyRemoteMetadata ok albumID=\(record.albumID) name=\(nameChanged) hidden=\(hiddenChanged) cover=\(coverChanged)")
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
            .flatMap { fingerprint in keys.first { $0.keychainLabel == fingerprint } }
            .map { hinted in [hinted] + keys.filter { $0.keychainLabel != hinted.keychainLabel } }
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
