//
//  CloudKitSyncCoordinator.swift
//  EncameraCore
//
//  Orchestrates CloudKit for one album: delta-syncs metadata into the existing
//  per-album MediaIndexStore, keeps an app-controlled evictable blob cache,
//  dedups concurrent blob fetches, applies cross-device deletes via tombstones,
//  and registers the zone push subscription. No app-UI wiring (chunk 04+).
//  All CloudKit I/O goes through the chunk-02 `CloudKitMediaStoring` seam.
//

import Foundation

public extension Notification.Name {
    /// Posted (from the app delegate's silent-push handler, and on scene-active as
    /// the backstop) when the CloudKit zone may have changed. Observers trigger a
    /// `sync` on the active CloudKit album.
    static let cloudKitZoneChanged = Notification.Name("EncameraCloudKitZoneChanged")
}

public actor CloudKitSyncCoordinator: DebugPrintable {

    private let albumID: String
    private let store: CloudKitMediaStoring
    private let cache: CloudKitBlobCache
    private let indexStore: MediaIndexStore
    private let bus: FileOperationBus

    /// In-flight blob fetches, so concurrent callers for the same record share one
    /// `fetchBlob` instead of issuing duplicates.
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// Records known-deleted locally (tombstoned) — a delete that lands mid-fetch wins.
    private var deletedRecordNames: Set<String> = []
    /// Latest server change tag per record, used to invalidate stale cache copies.
    private var changeTags: [String: String] = [:]
    /// Tombstoned records awaiting a hard purge on the next sync ("tombstone, propagate, then purge").
    private var pendingPurge: Set<String> = []

    public init(albumID: String,
                store: CloudKitMediaStoring,
                cache: CloudKitBlobCache,
                indexStore: MediaIndexStore,
                bus: FileOperationBus = .shared) {
        self.albumID = albumID
        self.store = store
        self.cache = cache
        self.indexStore = indexStore
        self.bus = bus
    }

    // MARK: - Sync

    /// The latest known server change tag for a record (so callers can detect a
    /// stale local copy after a remote re-upload).
    public func currentChangeTag(recordName: String) -> String? {
        changeTags[recordName]
    }

    private var activeSync: Task<Void, Error>?
    private var resyncRequested = false

    public func sync(albumID: String) async throws {
        // Single-flight that JOINS: a sync requested while one runs flags a re-run and
        // then awaits the active task (which loops to honor the request), so callers
        // never return before their changes are applied, yet overlapping calls coalesce
        // into at most one extra pass — no concurrent load–merge–save racing the index.
        if let active = activeSync {
            printDebug("sync join albumID=\(albumID) — a sync is already running; flagged a re-run and awaiting it")
            resyncRequested = true
            try await active.value
            return
        }
        let task = Task {
            // Clear the single-flight slot HERE, in the same synchronous stretch
            // as drainSync's final `resyncRequested` check (no suspension between
            // the check, the return, and this defer). A joiner therefore either
            // sees the task — and its flag is guaranteed to be honored by the
            // loop — or sees no task and starts a fresh sync. Clearing in the
            // caller instead left a window where a joiner's request could land
            // after the final check yet still join the finished task.
            defer { activeSync = nil }
            // Self-heal push registration on EVERY sync — a failed registration,
            // and also one the STORE invalidated after the fact (it clears its
            // persisted flag on `.zoneNotFound` when the zone is deleted in
            // iCloud Settings or the account is wiped). A coordinator-side
            // "already registered" bool went stale-true in that second case and
            // push-driven sync stayed silently dead for the life of the process.
            // The store's persisted-flag check makes the genuinely-registered
            // attempt a cheap no-op, so dedup lives there, not here.
            await startObserving()
            try await drainSync(albumID: albumID)
        }
        activeSync = task
        do {
            try await task.value
        } catch {
            printDebug("sync FAILED albumID=\(albumID) raw=\(error)")
            throw error
        }
    }

    private func drainSync(albumID: String) async throws {
        var pass = 0
        repeat {
            pass += 1
            resyncRequested = false
            do {
                try await performSync(albumID: albumID)
            } catch CloudKitMediaStoreError.changeTokenExpired {
                // The stored token is no longer valid: discard it and full-resync once.
                printDebug("drainSync token EXPIRED albumID=\(albumID) pass=\(pass) — resetting the change token and full-resyncing")
                await store.resetChangeToken()
                try await performSync(albumID: albumID)
            }
        } while resyncRequested
        printDebug("drainSync ok albumID=\(albumID) passes=\(pass)")
    }

    private func performSync(albumID: String) async throws {
        // Diff from the authoritative on-disk index, refreshing the store's cache.
        let loaded = await indexStore.reloadFromDisk()
        var entries = loaded?.entries ?? []
        printDebug("performSync start albumID=\(albumID) coordinatorAlbumID=\(self.albumID) indexLoaded=\(loaded != nil) entries=\(entries.count) pendingPurge=\(pendingPurge.count)")

        // Buffer gallery events and emit them ONLY after the index is durably saved,
        // so a save failure + retry can't fire duplicate refreshes for unpersisted items.
        var pendingCreates: [EncryptedMedia] = []
        var pendingDeletes: [EncryptedMedia] = []

        // Drain the whole delta, not just the first page (the store advances its
        // persisted token each call, so passing nil continues from where it left off).
        var token = await store.loadChangeToken()

        // If the on-disk index is missing/corrupt but a token is still set (e.g. the
        // index was cleared), the token would skip every historical record and leave
        // the album empty forever — so discard it and resync from scratch.
        if loaded == nil, await store.hasChangeToken() {
            printDebug("performSync token DISCARDED albumID=\(self.albumID) — on-disk index is missing/corrupt while a token exists; resyncing from scratch")
            await store.resetChangeToken()
            token = nil
        }
        var moreComing = true
        var page = 0
        var skippedOtherAlbum = 0
        while moreComing {
            page += 1
            let changeSet: CloudKitChangeSet
            do {
                changeSet = try await store.fetchChanges(since: token)
            } catch {
                printDebug("performSync fetchChanges FAILED albumID=\(self.albumID) page=\(page) hadToken=\(token != nil) raw=\(error)")
                throw error
            }
            printDebug("performSync page ok albumID=\(self.albumID) page=\(page) changed=\(changeSet.changed.count) deleted=\(changeSet.deleted.count) moreComing=\(changeSet.moreComing) newToken=\(changeSet.token != nil)")
            if changeSet.token != nil { token = changeSet.token }   // advance the cursor across pages
            moreComing = changeSet.moreComing

            for meta in changeSet.changed {
                // The zone is shared across albums; only apply records for THIS album.
                guard meta.albumID == self.albumID else {
                    skippedOtherAlbum += 1
                    continue
                }

                // A tombstone (deletedAt set) is a cross-device delete, not an upsert.
                if meta.deletedAt != nil {
                    let entryRemoved = entries.removeComponent(recordName: meta.recordName)
                    deletedRecordNames.insert(meta.recordName)
                    changeTags[meta.recordName] = nil
                    // Every device that OBSERVES a tombstone enqueues the hard purge,
                    // making it durable: if the deleting device is killed before its
                    // purge pass, the record (and its full-size blob asset) is still
                    // reclaimed by whichever device syncs next. Purges are idempotent —
                    // an already-gone record maps to `.notFound` and leaves the queue.
                    pendingPurge.insert(meta.recordName)
                    await cache.evict(recordName: meta.recordName)
                    let media = Self.media(forRecordName: meta.mediaID, albumID: self.albumID, mediaType: meta.mediaType)
                    if entryRemoved { pendingDeletes.append(media) } else { pendingCreates.append(media) }
                    printDebug("performSync tombstone recordName=\(meta.recordName) mediaID=\(meta.mediaID) mediaType=\(meta.mediaType) entryRemoved=\(entryRemoved) queuedForPurge=true")
                    continue
                }

                if let tag = meta.recordChangeTag { changeTags[meta.recordName] = tag }
                deletedRecordNames.remove(meta.recordName)
                // The shared `upsert` appends a new item or merges a Live Photo's
                // second component into the existing entry, and reports whether the
                // index actually changed. Refresh the gallery only on a real change —
                // a no-op re-sync stays silent, so a large initial sync doesn't fire
                // hundreds of redundant reconciles.
                if entries.upsert(Self.indexEntry(from: meta)) {
                    pendingCreates.append(Self.media(forRecordName: meta.mediaID, albumID: self.albumID, mediaType: meta.mediaType))
                    printDebug("performSync upsert recordName=\(meta.recordName) mediaID=\(meta.mediaID) mediaType=\(meta.mediaType) sizeBytes=\(meta.sizeBytes) changeTag=\(meta.recordChangeTag ?? "nil")")
                } else {
                    // Distinguishes a genuine no-op re-sync from a dropped record:
                    // both look identical in the pendingCreates count otherwise.
                    printDebug("performSync upsert skip recordName=\(meta.recordName) — index already current, no gallery refresh emitted")
                }
            }

            for recordName in changeSet.deleted {
                // The deleted list spans the whole shared zone; only act on records this
                // album actually holds (the deleted payload carries no albumID).
                let mediaID = MediaRecordName.mediaID(from: recordName)
                guard entries.contains(where: { $0.id == mediaID }) else {
                    printDebug("performSync hardDelete skip recordName=\(recordName) mediaID=\(mediaID) — not in this album's index (shared-zone delete for another album)")
                    continue
                }

                // Clear only this component; keep the entry if the other survives.
                let entryRemoved = entries.removeComponent(recordName: recordName)
                deletedRecordNames.insert(recordName)
                changeTags[recordName] = nil
                await cache.evict(recordName: recordName)
                let media = Self.media(forRecordName: mediaID, albumID: self.albumID, mediaType: .unknown)
                if entryRemoved { pendingDeletes.append(media) } else { pendingCreates.append(media) }
                printDebug("performSync hardDelete recordName=\(recordName) mediaID=\(mediaID) entryRemoved=\(entryRemoved)")
            }
        }
        if skippedOtherAlbum > 0 {
            printDebug("performSync skip albumID=\(self.albumID) otherAlbumRecords=\(skippedOtherAlbum) (shared zone)")
        }

        // Save the whole rebuilt index in ONE write before emitting or committing
        // the token, so a crash mid-sequence re-fetches rather than losing data.
        do {
            try await indexStore.replace(with: entries)
        } catch {
            // Nothing after this point runs: no gallery events, no token commit.
            // The next sync re-fetches the same delta from the un-advanced token.
            printDebug("performSync indexSave FAILED albumID=\(self.albumID) entries=\(entries.count) pendingCreates=\(pendingCreates.count) pendingDeletes=\(pendingDeletes.count) raw=\(error)")
            throw error
        }

        // The index is durably saved — now it is safe to notify the gallery.
        for media in pendingCreates { bus.didCreate(media) }
        if !pendingDeletes.isEmpty { bus.didDelete(pendingDeletes) }
        printDebug("performSync applied albumID=\(self.albumID) entries=\(entries.count) creates=\(pendingCreates.count) deletes=\(pendingDeletes.count) pages=\(page)")

        // Commit the change token ONLY after the index is durably saved. If the save
        // above threw, the token is not advanced and the next sync re-fetches.
        await store.commitChangeToken(token)
        if token == nil {
            // No token to commit means the next sync refetches the whole zone —
            // fine once, pathological if it repeats every pass.
            printDebug("performSync token WARNING albumID=\(self.albumID) — no token returned by the change feed; next sync will full-fetch")
        }

        // Follow-up pass: hard-purge anything we previously tombstoned. A stale
        // record (already gone from the zone) must not abort the whole sync — drop
        // it from the queue; keep only genuinely transient failures for a retry.
        for recordName in Array(pendingPurge) {
            do {
                try await store.delete(recordName: recordName)
                pendingPurge.remove(recordName)
                printDebug("purge ok recordName=\(recordName) remainingQueued=\(pendingPurge.count)")
            } catch let error as CloudKitMediaStoreError {
                if case .notFound = error {
                    pendingPurge.remove(recordName)
                    printDebug("purge skip recordName=\(recordName) — already gone from the zone; dropped from the queue")
                } else {
                    // else: leave it queued and try again on the next sync.
                    printDebug("purge FAILED recordName=\(recordName) mapped=\(error) — left queued for the next sync")
                }
            } catch {
                // Unknown error — leave queued for retry, don't fail the sync.
                printDebug("purge FAILED recordName=\(recordName) raw=\(error) — unmapped error, left queued for the next sync")
            }
        }
    }

    // MARK: - Blob residency

    public func ensureBlobLocal(recordName: String,
                                albumID: String,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if deletedRecordNames.contains(recordName) {
            printDebug("ensureBlobLocal FAILED recordName=\(recordName) reason=knownDeletedLocally")
            throw CloudKitMediaStoreError.notFound
        }

        let expectedTag = changeTags[recordName]
        if let cached = await cache.cachedURL(recordName: recordName, changeTag: expectedTag) {
            printDebug("ensureBlobLocal hit recordName=\(recordName) source=cache expectedTag=\(expectedTag ?? "nil") file=\(cached.lastPathComponent)")
            progress(1.0)
            return cached
        }
        if let existing = inFlight[recordName] {
            printDebug("ensureBlobLocal join recordName=\(recordName) — an identical fetch is already in flight")
            return try await existing.value
        }

        let store = self.store
        let cache = self.cache
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckdl-\(recordName)-\(UUID().uuidString)")

        printDebug("ensureBlobLocal MISS recordName=\(recordName) albumID=\(albumID) expectedTag=\(expectedTag ?? "nil") — downloading from CloudKit")

        let task = Task { () throws -> URL in
            // Inside an escaping Task closure, so the static form is required.
            try await store.fetchBlob(recordName: recordName, to: destination, progress: progress)
            let cachedURL = try await cache.store(recordName: recordName,
                                                  changeTag: expectedTag,
                                                  albumID: albumID,
                                                  from: destination)
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                // Non-fatal: the blob is already cached. But a leaked temp file per
                // download adds up, so it should be visible.
                Self.printDebug("ensureBlobLocal WARNING recordName=\(recordName) could not remove download temp file=\(destination.lastPathComponent) raw=\(error)")
            }
            return cachedURL
        }
        inFlight[recordName] = task

        do {
            let url = try await task.value
            inFlight[recordName] = nil
            // A delete that landed mid-fetch wins: discard the fetched copy.
            if deletedRecordNames.contains(recordName) {
                printDebug("ensureBlobLocal FAILED recordName=\(recordName) reason=deletedDuringFetch — evicting the just-fetched copy")
                await cache.evict(recordName: recordName)
                throw CloudKitMediaStoreError.notFound
            }
            printDebug("ensureBlobLocal ok recordName=\(recordName) source=network file=\(url.lastPathComponent)")
            return url
        } catch {
            inFlight[recordName] = nil
            printDebug("ensureBlobLocal FAILED recordName=\(recordName) albumID=\(albumID) raw=\(error)")
            throw error
        }
    }

    // MARK: - Upload

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        printDebug("upload start recordName=\(item.recordName) albumID=\(item.albumID) mediaType=\(item.mediaType) sizeBytes=\(item.sizeBytes)")
        let ref: CloudKitMediaRef
        do {
            ref = try await store.upload(item, progress: progress)
        } catch {
            printDebug("upload FAILED recordName=\(item.recordName) albumID=\(item.albumID) raw=\(error)")
            throw error
        }
        if let tag = ref.recordChangeTag { changeTags[ref.recordName] = tag }
        deletedRecordNames.remove(ref.recordName)
        // Cache the just-uploaded encrypted file (the authoring device keeps its copy).
        do {
            try await cache.store(recordName: ref.recordName,
                                  changeTag: ref.recordChangeTag,
                                  albumID: item.albumID,
                                  from: item.encryptedFileURL)
        } catch {
            // Swallowed on purpose (the upload itself succeeded), but it means the
            // authoring device will re-download its own freshly uploaded blob.
            printDebug("upload WARNING recordName=\(ref.recordName) local cache store failed; blob will be re-downloaded on next read raw=\(error)")
        }

        // Upsert (through the store's cache) merges a Live Photo's photo and video
        // components into one entry; the store persists and caches in one step.
        do {
            try await indexStore.upsert([Self.indexEntry(fromUpload: item)])
        } catch {
            printDebug("upload indexUpsert FAILED recordName=\(ref.recordName) mediaID=\(item.mediaID) — record is in CloudKit but not in the local index raw=\(error)")
            throw error
        }
        printDebug("upload ok recordName=\(ref.recordName) changeTag=\(ref.recordChangeTag ?? "nil")")
        // Surface the new item on the same bus the gallery already listens to.
        bus.didCreate(Self.media(forRecordName: item.mediaID, albumID: item.albumID, mediaType: item.mediaType))
        return ref
    }

    // MARK: - Delete

    /// Tombstone first (propagates by push), clear local state, then purge hard on
    /// the next `sync`. Preserves the tombstone-beats-blob safety property across
    /// devices (decision doc §1).
    public func remove(recordName: String, albumID: String) async throws {
        printDebug("remove start recordName=\(recordName) albumID=\(albumID)")
        do {
            try await store.tombstone(recordName: recordName)
        } catch {
            printDebug("remove tombstone FAILED recordName=\(recordName) albumID=\(albumID) — nothing cleared locally raw=\(error)")
            throw error
        }
        deletedRecordNames.insert(recordName)
        changeTags[recordName] = nil
        pendingPurge.insert(recordName)
        await cache.evict(recordName: recordName)

        // Clear only this component; the entry survives if the other component does.
        // The store persists and caches; a no-op (record already absent) skips the write.
        let entryRemoved: Bool
        do {
            entryRemoved = try await indexStore.removeComponent(recordName: recordName)
        } catch {
            // The record is already tombstoned server-side, so a failure here leaves
            // the local index claiming an item that no longer exists remotely.
            printDebug("remove indexRemove FAILED recordName=\(recordName) — record is tombstoned in CloudKit but still in the local index raw=\(error)")
            throw error
        }
        printDebug("remove ok recordName=\(recordName) entryRemoved=\(entryRemoved) queuedForPurge=\(pendingPurge.count)")

        emitDeletion(mediaID: MediaRecordName.mediaID(from: recordName), entryRemoved: entryRemoved)
    }

    /// Emit a delete when the whole item is gone, otherwise a refresh so the
    /// gallery re-reads the still-present item rather than dropping it.
    private func emitDeletion(mediaID: String, entryRemoved: Bool) {
        let media = Self.media(forRecordName: mediaID, albumID: self.albumID, mediaType: .unknown)
        if entryRemoved {
            bus.didDelete([media])
        } else {
            bus.didCreate(media)
        }
    }

    public func evict(recordName: String) async throws {
        printDebug("evict start recordName=\(recordName) albumID=\(albumID)")
        await cache.evict(recordName: recordName)
    }

    public func evictAll(olderThan date: Date) async throws {
        printDebug("evictAll start albumID=\(albumID) olderThan=\(date)")
        await cache.evictAll(olderThan: date)
    }

    // MARK: - Push

    public func startObserving() async {
        guard await store.accountAvailable() else {
            printDebug("startObserving skip albumID=\(albumID) reason=accountUnavailable — no push subscription registered")
            return
        }   // skip when no account
        do {
            try await store.registerZoneSubscription()
            printDebug("startObserving ok albumID=\(albumID) zone subscription registered")
        } catch {
            printDebug("startObserving FAILED albumID=\(albumID) zone subscription not registered; push-driven sync is off until the next sync retries raw=\(error)")
        }
    }

    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        printDebug("handleRemoteNotification start albumID=\(albumID) userInfoKeys=\(userInfo.keys.count)")
        do {
            try await sync(albumID: albumID)
            printDebug("handleRemoteNotification ok albumID=\(albumID)")
        } catch {
            // Swallowed by the original `try?`: a push-triggered sync failure was
            // completely invisible, so the album silently stays stale.
            printDebug("handleRemoteNotification FAILED albumID=\(albumID) raw=\(error)")
        }
    }

    // MARK: - Mapping helpers

    /// Maps one CloudKit component record to a single-component index entry.
    /// Source-specific (CloudKit -> entry), so it stays here rather than on the
    /// shared algebra — but it feeds the shared `upsert`. `internal` for the
    /// disk/cloud index-equivalence test.
    static func indexEntry(from meta: CloudKitMediaMetadata) -> MediaIndexEntry {
        // `createdAt` is the record's capture/encryption date — use it for BOTH so the
        // default encrypted-date gallery sort orders synced items by time, not last.
        MediaIndexEntry(id: meta.mediaID,
                        hasPhotoComponent: meta.mediaType == .photo,
                        hasVideoComponent: meta.mediaType == .video,
                        dateEncrypted: meta.createdAt,
                        dateTaken: meta.createdAt,
                        subtypeRawValue: 0)
    }

    private static func indexEntry(fromUpload item: CloudKitMediaUpload) -> MediaIndexEntry {
        // Use the capture date for BOTH dates so a freshly uploaded item sorts
        // consistently with the same item once it comes back through delta sync.
        MediaIndexEntry(id: item.mediaID,
                        hasPhotoComponent: item.mediaType == .photo,
                        hasVideoComponent: item.mediaType == .video,
                        dateEncrypted: item.createdAt,
                        dateTaken: item.createdAt,
                        subtypeRawValue: 0)
    }

    /// A lightweight `EncryptedMedia` carrying just the id/type so the gallery can
    /// react through the same `FileOperationBus` it uses for local file ops. The
    /// URL is synthetic — consumers key on `id`.
    private static func media(forRecordName recordName: String,
                              albumID: String,
                              mediaType: MediaType) -> EncryptedMedia {
        let url = URL(fileURLWithPath: "/cloudkit/\(albumID)/\(recordName)")
        return EncryptedMedia(source: url, mediaType: mediaType, id: recordName)
    }
}
