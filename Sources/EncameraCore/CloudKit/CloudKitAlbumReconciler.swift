//
//  CloudKitAlbumReconciler.swift
//  EncameraCore
//
//  Makes CloudKit the authoritative, cross-device source of truth for which albums
//  exist. Two-way reconcile against the `EncAlbum` records in the zone:
//   - Pull: a remote album with no local materialization becomes a local discovery
//     marker (so it shows in the grid and gets its media reconciled); an album the
//     change feed reports deleted removes the local materialization.
//   - Push (self-heal): a local `.cloudKit` album that has NEVER been confirmed on
//     the server is uploaded, so an `EncAlbum` save that failed while offline at
//     create-time is recovered.
//
//  Deletions come from the zone change feed (`deletedAlbumIDs`), not from absence
//  in `fetchAllAlbums`. That distinction is the whole design: the query's index is
//  eventually consistent, so absence there is not evidence of anything, and a
//  reconciler that treated it as a delete would race every fresh create. Absence
//  is disambiguated locally instead, by whether the album was ever published
//  — no server-side tombstone required.
//
//  The album-id hash is one-way, so a fresh device recovers the plaintext name by
//  matching a synced album key against the hash (XChaCha20's MAC rejects wrong keys;
//  the keyed-hash equality is the authoritative confirmation), then decrypts the
//  name ciphertext. Albums whose key is not present on this device (key backup off)
//  cannot be materialized and are reported via the locked-out count.
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

    public init(store: CloudKitMediaStoring,
                keyManager: KeyManager,
                albumManager: AlbumManaging,
                deleteQueue: CloudKitAlbumDeleteQueue = CloudKitAlbumDeleteQueue(),
                publishRegistry: CloudKitAlbumPublishRegistry = CloudKitAlbumPublishRegistry()) {
        self.store = store
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.deleteQueue = deleteQueue
        self.publishRegistry = publishRegistry
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
        var localByHash = localCloudKitAlbumsByHash()
        var remoteIDs = Set<String>()
        var lockedOut = 0
        var adopted = 0
        printDebug("reconcileAlbums state keys=\(keys.count) localCloudKitAlbums=\(localByHash.count) remote=\(remote.count)")
        for albumID in deletedRemotely { localByHash[albumID] = nil }

        for record in remote {
            remoteIDs.insert(record.albumID)

            if pendingDeletes.contains(record.albumID) {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=deletePending")
                continue
            }

            publishRegistry.markPublished(record.albumID)

            if localByHash[record.albumID] != nil {
                printDebug("reconcileAlbums pull skip albumID=\(record.albumID) reason=alreadyMaterialized")
                continue
            }

            guard let match = Self.match(record: record, keys: keys) else {
                lockedOut += 1
                printDebug("reconcileAlbums pull MISS albumID=\(record.albumID) reason=noMatchingKey candidateKeys=\(keys.count)")
                //TODO: We have to surface this!
                continue
            }
            printDebug("reconcileAlbums pull adopt albumID=\(record.albumID) isHidden=\(record.isHidden) createdAt=\(record.createdAt)")
            albumManager.adoptCloudKitAlbum(name: match.name,
                                            key: match.key,
                                            createdAt: record.createdAt,
                                            isHidden: record.isHidden)
            if let coverID = record.coverMediaID {
                let adoptedAlbum = Album(name: match.name, storageOption: .cloudKit, creationDate: record.createdAt, key: match.key)
                let sidecar = AlbumCoverSidecar(album: adoptedAlbum)
                Task { try? await sidecar.setCoverMediaID(coverID) }
            }
            adopted += 1
        }

        var pushed = 0
        var deletedLocally = deletedRemotely.count
        for (hash, album) in localByHash where !remoteIDs.contains(hash) && !pendingDeletes.contains(hash) {
            if publishRegistry.isPublished(hash) {
                printDebug("reconcileAlbums delete albumID=\(hash) reason=publishedButAbsentRemotely")
                albumManager.delete(album: album)
                publishRegistry.forget(hash)
                deletedLocally += 1
                continue
            }

            guard let albumFingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: album,
                                                                                 keyManager: keyManager,
                                                                                 storedKeysSnapshot: keys) else {
                printDebug("reconcileAlbums push skip albumID=\(hash) reason=noKeyDecryptsTheName")
                continue
            }
            let rawCover = albumManager.getAlbumCoverImageId(album: album)
            let coverMediaID = (rawCover == nil || rawCover == "none") ? nil : rawCover
            let upload = CloudKitAlbumUpload(albumID: hash,
                                             encName: album.encryptedPathComponent,
                                             createdAt: album.creationDate,
                                             isHidden: albumManager.isAlbumHidden(album),
                                             keyFingerprint: albumFingerprint,
                                             coverMediaID: coverMediaID)
            printDebug("reconcileAlbums push start albumID=\(hash) isHidden=\(upload.isHidden)")
            do {
                try await store.saveAlbum(upload)
                publishRegistry.markPublished(hash)
                pushed += 1
                printDebug("reconcileAlbums push ok albumID=\(hash)")
            } catch {
                printDebug("reconcileAlbums push FAILED albumID=\(hash) error=\(error)")
            }
        }

        printDebug("reconcileAlbums ok remote=\(remote.count) adopted=\(adopted) deletedLocally=\(deletedLocally) pushed=\(pushed) lockedOut=\(lockedOut) stillPendingDeletes=\(pendingDeletes.count)")
        return lockedOut
    }

    /// Applies album deletions the zone change feed reports, and returns the ids
    /// removed. This is the authoritative cross-device delete signal.
    ///
    /// Local removal routes through `AlbumManager.delete` so observers get the
    /// broadcast, `currentAlbum` is fixed up, and synced-store / hidden-state
    /// entries are cleaned — the same four things a user-initiated delete does.
    private func applyRemoteDeletions() async -> Set<String> {
        var removed: Set<String> = []
        let localByHash = localCloudKitAlbumsByHash()
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
                guard let album = localByHash[albumID] else {
                    printDebug("applyRemoteDeletions skip albumID=\(albumID) reason=notMaterializedLocally")
                    continue
                }
                printDebug("applyRemoteDeletions delete albumID=\(albumID)")
                albumManager.delete(album: album)
                removed.insert(albumID)
            }
            for albumMeta in changeSet.changedAlbums {
                publishRegistry.markPublished(albumMeta.albumID)
                if let localAlbum = localByHash[albumMeta.albumID] {
                    if albumManager.getAlbumCoverImageId(album: localAlbum) == nil {
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
        printDebug("applyRemoteDeletions ok removed=\(removed.count)")
        return removed
    }

    // MARK: - Matching

    /// Find the synced key that owns `record`: the album-name ciphertext decrypts
    /// under that key AND the keyed hash of the recovered name equals the record name
    /// (the album id). Pure + `internal` so it can be unit-tested directly.
    static func match(record: CloudKitAlbumMetadata, keys: [PrivateKey]) -> (name: String, key: PrivateKey)? {
        let ordered = record.keyFingerprint
            .flatMap { fingerprint in keys.first { $0.keychainLabel == fingerprint } }
            .map { hinted in [hinted] + keys.filter { $0.keychainLabel != hinted.keychainLabel } }
            ?? keys
        for key in ordered {
            let name = Album.decryptAlbumName(record.encName, key: key)
            if SyncedStoreEncryptionHandler.keyedHash(name, keyBytes: key.keyBytes) == record.albumID {
                printDebug("match hit albumID=\(record.albumID)")
                return (name, key)
            }
        }
        // Never log the decryption candidates themselves — the recovered name is
        // user data. Only the hash and the number of keys tried are safe.
        printDebug("match MISS albumID=\(record.albumID) keysTried=\(keys.count)")
        return nil
    }

    // MARK: - Local materialization

    private func localCloudKitAlbumsByHash() -> [String: Album] {
        var byHash: [String: Album] = [:]
        var unhashable = 0
        for album in albumManager.fetchAlbumsFromSources(includingHidden: true)
            where album.storageOption == .cloudKit {
            if let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) {
                byHash[hash] = album
            } else {
                unhashable += 1
            }
        }
        if unhashable > 0 {
            printDebug("localCloudKitAlbumsByHash WARNING unhashableAlbums=\(unhashable) hashed=\(byHash.count)")
        }
        printDebug("localCloudKitAlbumsByHash ok count=\(byHash.count)")
        return byHash
    }

}
