//
//  MigrationItemStep.swift
//  EncameraCore
//
//  The per-item work of a transfer between local storage and CloudKit, one step
//  per direction. `CloudKitMigrationManager` owns the run loop, the preflights and
//  the checkpointing cadence; a step only advances one item's state machine and
//  persists after every transition it makes.
//

import Foundation
import Combine
import CloudKit

// MARK: - Context

/// Everything a step needs for one run, built once from the plan.
struct MigrationRunContext {
    let source: Album
    let destination: Album
    let sourceModel: DataStorageModel?
    let destinationModel: DataStorageModel?
    /// The `albumID` of the CloudKit side: the destination for `toCloudKit`, the
    /// source for `toLocal`.
    let cloudKitAlbumID: String
    let coordinator: CloudKitSyncCoordinator
    let store: CloudKitMediaStoring
    /// Where captures wait before they reach CloudKit. A move back to this device
    /// copies an item still waiting there from its durable file.
    let uploadQueue: CloudKitUploadQueue
    /// Saves the plan after each state transition.
    let savePlan: (MigrationPlan) async throws -> Void
    let storedKeys: [PrivateKey]
    let keyManager: KeyManager
    let isCancelRequested: () -> Bool
    /// Records that an item failed because its key is not on this device.
    let noteMissingKey: () -> Void
    /// Records why an item failed because its key could not be proven: no key on
    /// this device opens it, or its bytes are not readable as encrypted media.
    var noteKeyProofFailure: (CloudKitKeyStamp.Failure) -> Void = { _ in }
    /// Whether an item whose record belongs to another album is deferred
    /// (`pending` with `.recordInAnotherAlbum`) rather than `skipped`.
    var defersRecordsInAnotherAlbum = false
    let setPhase: (MigrationPhase?, MigrationPlan, String?) -> Void
    /// Reports how far an item's transfer has got, 0...1, from any queue.
    let reportTransferProgress: @Sendable (_ index: Int, _ fraction: Double) -> Void
    /// Asked before a re-encryption writes plaintext and at each chunk boundary
    /// while it runs; true abandons it with `MigrationReencryptionAbandoned`.
    var shouldStopReencryption: @Sendable () -> Bool = { false }
    /// Where an item's uploaded blob enters the blob cache's eviction order.
    var cacheInsertion: (MigrationItem) -> CloudKitBlobCache.Insertion = { _ in .warm }
}

// MARK: - Step

@MainActor
protocol MigrationItemStep {
    /// Drives the item from `pending` (or an interrupted `uploading`) to `verified`:
    /// the bytes are at the destination and confirmed there. May instead leave it
    /// `skipped` or `failed`, which the run loop reads.
    func transfer(at index: Int, in plan: inout MigrationPlan, context: MigrationRunContext) async throws

    /// Removes the source copy of a `verified` item, leaving it `sourceDeleted`.
    /// `verifiedThisRun` is false when the item entered the run already `verified`,
    /// so its verification may be stale; when true, a step may check the copy
    /// against what it recorded at verification instead of asking the server. A
    /// step that finds it stale resets the item to `pending` and returns, and the
    /// run loop re-drives it.
    func removeSource(at index: Int,
                      in plan: inout MigrationPlan,
                      verifiedThisRun: Bool,
                      context: MigrationRunContext) async throws
}

extension MigrationPlan: DebugPrintable {
    /// Marks an item failed with an error description, a partial failure recorded
    /// as the record's own error. Returns the failure that ends the whole run when
    /// the error is one, a full iCloud or a lost account; nil when it fails only
    /// the item.
    @discardableResult
    mutating func markFailed(_ index: Int, _ error: Error) -> MigrationFailureReason? {
        let storeError = (error as? CloudKitMediaStoreError)?.unwrappingPartial
        let recorded: Error = storeError ?? error
        items[index].state = .failed
        items[index].lastError = "\(recorded)"
        printDebug("item FAILED recordName=\(items[index].recordName) error=\(recorded)")
        switch storeError {
        case .quotaExceeded: return .quota
        case .accountUnavailable: return .accountUnavailable
        default: return nil
        }
    }

    /// Resets any item left mid-transfer back to `pending` so a resume re-drives it
    /// cleanly. `verified`/`sourceDeleted`/`uploaded` work is preserved.
    mutating func revertInFlight() {
        for index in items.indices where items[index].state == .uploading {
            items[index].state = .pending
        }
    }
}

// MARK: - Local / iCloud Drive -> CloudKit

@MainActor
struct LocalToCloudKitStep: MigrationItemStep, DebugPrintable {

    /// Max automatic retries for a `CloudKit retry(after:)` before an item is failed.
    static let maxRetriesPerItem = 3

    /// Uploads the existing ciphertext and verifies the record. Each phase is guarded
    /// by the persisted state and advances it exactly one step, persisting before
    /// moving on — so a crash between any two phases resumes correctly. Re-uploading
    /// is avoided by re-verifying an interrupted `uploading` item rather than blindly
    /// re-saving (a stable record name + `ifServerRecordUnchanged` would otherwise
    /// conflict).
    func transfer(at index: Int, in plan: inout MigrationPlan, context: MigrationRunContext) async throws {
        let item = plan.items[index]
        let encURL = context.sourceModel?.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
        let previewURL = context.sourceModel?.previewURLForMedia(withID: item.mediaID)

        // Recover an interrupted upload: confirm-or-restart rather than re-save.
        if plan.items[index].state == .uploading {
            switch try await Self.presenceInCloudKit(item, context: context) {
            case .inAnotherAlbum(let owner):
                try await Self.setAsideAsOwnedByAnotherAlbum(at: index, owner: owner, in: &plan, context: context)
                return
            case .present:
                plan.items[index].state = .uploaded
            case .absent, .sizeMismatch:
                plan.items[index].state = .pending
            }
            try await context.savePlan(plan)
        }

        // 1. Upload the existing ciphertext (no re-encryption).
        upload: if plan.items[index].state == .pending || plan.items[index].state == .failed {
            // No source ciphertext means a stale index entry with nothing to migrate.
            // Skip it terminally rather than failing it forever — a single missing file
            // must never wedge the whole album short of completion.
            //
            // EXCEPT when the file is still sitting there as an iCloud Drive
            // placeholder: then the bytes exist, they just aren't on this device yet,
            // and this batch's download did not finish. `.skipped` is terminal and
            // counts as done, so skipping it would let the album finalize, flip to
            // CloudKit and drop the source directory reference while the user's photo
            // is still only in iCloud Drive. That is data loss. Fail it instead —
            // retryable, and it blocks finalize until it really does move.
            // `isMaterialized`, not `fileExists`: an evicted iCloud Drive file keeps
            // its path, so `fileExists` would wave a placeholder straight through to
            // `CKAsset(fileURL:)`. On the rig that produced nine identical
            // "Retry after 3.0s" upload failures and no useful diagnosis.
            // Same scoping as enumeration: only an iCloud Drive source can present a
            // file whose path resolves while its bytes are elsewhere, and the
            // ubiquity lookup is too expensive to run per item on a local migration.
            let sourceIsPresent = plan.source.storage == .icloud
                ? encURL.map(ICloudPlaceholderName.isMaterialized) ?? false
                : encURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard let encURL, sourceIsPresent else {
                if let encURL, ICloudPlaceholderName.existsInAnyForm(encURL) {
                    printDebug("item FAILED recordName=\(item.recordName) — still an iCloud Drive placeholder")
                    plan.items[index].state = .failed
                    // Keep the materializer's reason if it recorded one; it says why.
                    if plan.items[index].lastError == nil {
                        plan.items[index].lastError = "iCloud Drive file has not been downloaded yet"
                    }
                    try await context.savePlan(plan)
                    return
                }
                printDebug("item SKIPPED recordName=\(item.recordName) — source ciphertext missing at \(encURL?.lastPathComponent ?? "<no url>")")
                plan.items[index].state = .skipped
                plan.items[index].lastError = "source ciphertext missing"
                try await context.savePlan(plan)
                return
            }

            // Record names come from media ids, so another album can already hold a
            // record with this name — the same album migrated from another device
            // into a different album, say. Saving over it would re-parent it, so
            // it is left where it is and the local original stays.
            let owner = try await Self.checkOwner(at: index, in: &plan, context: context)
            if owner == .anotherAlbum { return }

            // A legacy video whose record is already in this album (another
            // device's upload, or an earlier run whose checkpoint was lost) is not
            // re-encrypted: a new encryption's chunks would overwrite the ones the
            // committed record describes. It goes straight to verification.
            // Chunks with no record are not checked: nothing reaps uncommitted
            // chunks and they do not name the device that wrote them, so the
            // re-encryption overwrites them.
            if owner == .thisAlbum, Self.needsReencryption(item, at: encURL) {
                printDebug("item re-encryption SKIPPED recordName=\(item.recordName) — the record is already in this album, verifying")
                plan.items[index].state = .uploaded
                plan.items[index].lastError = nil
                try await context.savePlan(plan)
                break upload
            }

            // Which key encrypted THIS file, proven against its own bytes. An album can
            // hold a file written under another key, so the album's key is an assumption
            // and the record's `keyFingerprint` is the key readers try first and the one a
            // missing-key prompt names. A file whose key is not on this device
            // fails here and never uploads: a record naming a guessed key is worse than
            // no record, and the local original is the only copy left.
            let proven: CloudKitKeyStamp.StampedSource
            do {
                proven = try await CloudKitKeyStamp.stampedSourceForUpload(at: encURL,
                                                                           keyManager: context.keyManager,
                                                                           storedKeysSnapshot: context.storedKeys)
            } catch {
                printDebug("item FAILED recordName=\(item.recordName) — key not established: \(error)")
                if case .missingKey = error as? CloudKitKeyStamp.Failure { context.noteMissingKey() }
                if let failure = error as? CloudKitKeyStamp.Failure { context.noteKeyProofFailure(failure) }
                plan.items[index].state = .failed
                plan.items[index].lastError = (error as? ErrorDescribable)?.displayDescription
                    ?? "could not establish which key encrypted this file"
                try await context.savePlan(plan)
                return
            }

            plan.items[index].state = .uploading
            plan.items[index].lastError = nil
            try await context.savePlan(plan)

            defer { proven.cleanUp() }
            let thumbURL = previewURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

            // Chunked branch. An ENC3 source (a large capture/import made after
            // chunked storage shipped) slices and uploads the EXISTING ciphertext
            // — no crypto work, preserving "migration never re-encrypts" — and its
            // chunk upload resumes by probe. A large ENC2 video (the user's
            // pre-existing library) is re-encrypted into ENC3 first, so migration
            // produces chunk records for it too. The re-encrypt is redone from
            // scratch on a crash — the temp is not checkpointed — so its upload
            // rewrites every chunk.
            var uploadFileURL = proven.uploadURL
            var chunkGeometry: (chunkCount: Int, plaintextLength: Int64)?
            var reencryptScratch: URL?
            // The item's transfer after its download: a re-encrypt, when there is
            // one, takes `reencryptShare` of it and the upload the rest.
            let report = context.reportTransferProgress
            let transferStart = plan.downloadShare
            let reencryptShare = 0.4
            defer { if let reencryptScratch { MigrationReencryptScratch.release(reencryptScratch) } }
            if SeekableEncryptedHeader.isSeekableFormat(fileURL: encURL) {
                let header = try SeekableEncryptedHeader.read(fromFileAt: encURL).header
                chunkGeometry = (header.chunkCount, Int64(header.plaintextLength))
            } else if Self.needsReencryption(item, at: encURL) {
                context.setPhase(.preparing, plan, item.mediaID)
                // Throws, failing the item with its original kept, when the ENC3
                // output does not decrypt back to the original's plaintext.
                let reencrypted = try await Self.reencryptToSeekable(sourceENC2: encURL,
                                                                     mediaID: item.mediaID,
                                                                     keyBytes: proven.key.keyBytes,
                                                                     shouldStopReencryption: context.shouldStopReencryption) { fraction in
                    report(index, transferStart + (1 - transferStart) * reencryptShare * fraction)
                }
                reencryptScratch = reencrypted.scratchDirectory
                uploadFileURL = reencrypted.url
                chunkGeometry = (reencrypted.header.chunkCount, Int64(reencrypted.header.plaintextLength))
            }

            let descriptor = CloudKitMediaRecordDescriptor(
                albumID: context.cloudKitAlbumID,
                mediaID: item.mediaID,
                recordName: item.recordName,
                mediaType: item.mediaType,
                createdAt: item.createdAt,
                sizeBytes: item.sizeBytes,
                keyFingerprint: proven.fingerprint,
                chunkCount: chunkGeometry?.chunkCount ?? 0,
                plaintextLength: chunkGeometry?.plaintextLength ?? 0
            )
            // A re-encryption has a new file id every attempt, so chunks an earlier
            // attempt left behind would not decrypt under this attempt's header.
            let upload = CloudKitMediaUpload(descriptor: descriptor,
                                             encryptedFileURL: uploadFileURL,
                                             encryptedThumbURL: thumbURL,
                                             existingChunks: reencryptScratch == nil ? .resumeByProbe : .overwrite)
            context.setPhase(.uploading, plan, item.mediaID)
            let uploadStart = transferStart + (1 - transferStart) * (reencryptScratch == nil ? 0 : reencryptShare)
            do {
                try await Self.uploadWithRetry(upload, coordinator: context.coordinator, plan: plan, itemName: item.mediaID,
                                               cacheInsertion: context.cacheInsertion(item),
                                               setPhase: context.setPhase) { fraction in
                    report(index, uploadStart + (1 - uploadStart) * fraction)
                }
            } catch let error as CloudKitMediaStoreError {
                // A record with this stable name is already on the server (e.g. a prior
                // run whose checkpoint was lost re-uploaded it): the bytes are there, so
                // don't re-save into a conflict loop — fall through to the verify gate,
                // which confirms presence, size and album before any source delete. The
                // real adapter wraps the per-record `.conflict` in `.partial`, so unwrap.
                guard case .conflict = CloudKitMigrationManager.unwrapPartial(error) else { throw error }
                printDebug("item upload conflict recordName=\(item.recordName) — record already on server, falling through to verify")
            }
            printDebug("item uploaded recordName=\(item.recordName)")
            plan.items[index].state = .uploaded
            try await context.savePlan(plan)
        }

        // 2. Verify the record is durably in CloudKit before touching the original.
        if plan.items[index].state == .uploaded {
            context.setPhase(.verifying, plan, item.mediaID)
            switch try await Self.presenceInCloudKit(item, context: context) {
            case .inAnotherAlbum(let owner):
                try await Self.setAsideAsOwnedByAnotherAlbum(at: index, owner: owner, in: &plan, context: context)
                return
            case .absent, .sizeMismatch:
                printDebug("item VERIFY FAILED recordName=\(item.recordName) — refusing to delete the local original")
                throw MigrationError.verificationFailed(recordName: item.recordName)
            case .present:
                break
            }
            plan.items[index].state = .verified
            if let encURL {
                plan.items[index].verifiedSizeBytes = encURL.fileSizeBytes()
                plan.items[index].verifiedModificationDate = Self.modificationDate(of: encURL)
            }
            try await context.savePlan(plan)
        }
    }

    /// The file's content modification date, or nil when it cannot be read.
    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func removeSource(at index: Int,
                      in plan: inout MigrationPlan,
                      verifiedThisRun: Bool,
                      context: MigrationRunContext) async throws {
        let item = plan.items[index]
        let encURL = context.sourceModel?.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
        // The blob is in CloudKit AND in the on-device CloudKit cache
        // (`coordinator.upload` stored it), so this never removes the last copy.
        if plan.items[index].state == .verified {
            // A cancel requested mid-item stops BEFORE this irreversible delete: the
            // verified bytes are safe in CloudKit and the local original is untouched,
            // so the album stays fully usable in its source storage.
            if context.isCancelRequested() { throw CloudKitMediaStoreError.cancelled }
            // A verification from an earlier run is arbitrarily stale (the record may
            // have been erased or moved to another album from another device, or the
            // zone deleted, since). Never delete a local original against a stale
            // verification: re-verify with the same cheap fetch-by-id first, and
            // re-drive the upload if the record is gone.
            if !verifiedThisRun {
                context.setPhase(.verifying, plan, item.mediaID)
                switch try await Self.presenceInCloudKit(item, context: context) {
                case .inAnotherAlbum(let owner):
                    try await Self.setAsideAsOwnedByAnotherAlbum(at: index, owner: owner, in: &plan, context: context)
                    return
                case .absent, .sizeMismatch:
                    printDebug("item STALE VERIFICATION recordName=\(item.recordName) — record gone since the earlier run, re-driving upload")
                    plan.items[index].state = .pending
                    plan.items[index].lastError = "stale verification: record no longer in CloudKit"
                    try await context.savePlan(plan)
                    return
                case .present:
                    break
                }
            }
            printDebug("item deleting source recordName=\(item.recordName) verified in CloudKit")
            context.setPhase(.removingLocalCopy, plan, item.mediaID)
            if let encURL {
                try? FileManager.default.removeItem(at: encURL)
                // An evicted iCloud Drive original may be on disk only as its
                // `.icloud` brick.
                if plan.source.storage == .icloud {
                    try? FileManager.default.removeItem(at: ICloudPlaceholderName.placeholderURL(forMaterialized: encURL))
                }
            }
            // The preview is NOT deleted: it lives in the global, storage-agnostic
            // thumbnail directory that the migrated `.cloudKit` album reads from
            // the same path (as `CloudKitToLocalStep` relies on in the
            // reverse direction). Deleting it would force a thumbnail re-download for
            // every item — and for a Live Photo would strip the shared preview
            // before its second component uploads.
            plan.items[index].state = .sourceDeleted
            try await context.savePlan(plan)
        }
    }

    /// Who owns the item's record on the server.
    private enum RecordOwner: Equatable {
        case none
        case thisAlbum
        case anotherAlbum
    }

    /// Asks `confirmAlbum` who owns the item's record, and marks the item `skipped`
    /// when another album does. `skipped` is terminal, so the run can finish, and
    /// it never removes the source, so the local original keeps the item on this
    /// device (and keeps its directory from being removed as drained).
    private static func checkOwner(at index: Int,
                                   in plan: inout MigrationPlan,
                                   context: MigrationRunContext) async throws -> RecordOwner {
        let recordName = plan.items[index].recordName
        guard let owner = try await context.store.confirmAlbum(recordName: recordName) else { return .none }
        guard owner != context.cloudKitAlbumID else { return .thisAlbum }
        try await setAsideAsOwnedByAnotherAlbum(at: index, owner: owner, in: &plan, context: context)
        return .anotherAlbum
    }

    /// Whether the item's upload re-encrypts it: a legacy (not ENC3) video at or
    /// over the chunking threshold.
    private static func needsReencryption(_ item: MigrationItem, at encURL: URL) -> Bool {
        item.mediaType == .video
            && item.sizeBytes >= Int64(SeekableEncryptedFormat.threshold)
            && !SeekableEncryptedHeader.isSeekableFormat(fileURL: encURL)
    }

    private static func setAsideAsOwnedByAnotherAlbum(at index: Int,
                                                  owner: String,
                                                  in plan: inout MigrationPlan,
                                                  context: MigrationRunContext) async throws {
        plan.items[index].lastError = "a record with this name belongs to another album"
        if context.defersRecordsInAnotherAlbum {
            printDebug("item DEFERRED recordName=\(plan.items[index].recordName) — the record belongs to album \(owner), not \(context.cloudKitAlbumID)")
            plan.items[index].state = .pending
            plan.items[index].deferralReason = .recordInAnotherAlbum
        } else {
            printDebug("item SKIPPED recordName=\(plan.items[index].recordName) — the record belongs to album \(owner), not \(context.cloudKitAlbumID)")
            plan.items[index].state = .skipped
        }
        try await context.savePlan(plan)
    }

    // MARK: - Upload with retry

    /// Uploads with bounded `retry(after:)` backoff (honoring CloudKit's requested
    /// delay). Non-retryable errors (quota, account, conflict, ...) propagate so the
    /// run loop can halt or fail the item as appropriate.
    /// `plan`/`itemName` are carried purely so the backoff can publish `.retrying` —
    /// a long CloudKit-requested delay is otherwise indistinguishable from a stall.
    private static func uploadWithRetry(_ upload: CloudKitMediaUpload,
                                        coordinator: CloudKitSyncCoordinator,
                                        plan: MigrationPlan,
                                        itemName: String,
                                        cacheInsertion: CloudKitBlobCache.Insertion,
                                        setPhase: (MigrationPhase?, MigrationPlan, String?) -> Void,
                                        progress: @escaping @Sendable (Double) -> Void) async throws {
        var attempt = 0
        while true {
            do {
                _ = try await coordinator.upload(upload, progress: progress, cacheInsertion: cacheInsertion)
                return
            } catch let error as CloudKitMediaStoreError {
                guard case .retry(let after) = CloudKitMigrationManager.unwrapPartial(error) else { throw error }
                attempt += 1
                if attempt > maxRetriesPerItem { throw CloudKitMediaStoreError.retry(after: after) }
                setPhase(.retrying, plan, itemName)
                let capped = min(max(after, 0), 30)
                if capped > 0 { try await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000)) }
                setPhase(.uploading, plan, itemName)
            }
        }
    }

    // MARK: - Verification

    /// The item's record measured against this move's album and the item's planned
    /// size: the gate that must pass before a source delete. A size mismatch counts
    /// as no copy. A record that another device has moved to another album since
    /// this run's owner check is not a copy of this move.
    private static func presenceInCloudKit(_ item: MigrationItem,
                                           context: MigrationRunContext) async throws -> CloudKitRecordPresence {
        try await CloudKitRecordPresence.check(recordName: item.recordName,
                                               albumID: context.cloudKitAlbumID,
                                               sizeBytes: item.sizeBytes,
                                               store: context.store)
    }

    /// Runs on the re-encrypted ENC3 file before it is verified. Tests use it to
    /// stand in for a writer that produces a corrupt or short file.
    static var afterReencryptWriteForTesting: ((URL) throws -> Void)?

    /// Re-encrypts an ENC2 video into ENC3 so migration produces chunk records
    /// for the user's pre-existing large videos, then decrypts the result through
    /// the playback reader and compares it with the plaintext it came from (see
    /// `ReencryptVerifier`): the ENC3 file is the copy that replaces the original,
    /// so one that does not play back is rejected here, before upload. Embedded
    /// metadata is carried across.
    ///
    /// The plaintext is written to a scratch directory (as playback already does
    /// today). The caller releases `scratchDirectory`, which holds the returned
    /// file, once it is uploaded; on a throw it is already gone, and one left by a
    /// crash is removed by the next `TempFileAccess.cleanupTemporaryFiles()`. A
    /// streaming ENC2-read -> ENC3-write pipe would keep the plaintext off disk
    /// altogether.
    /// `progress` runs 0...1 over the decrypt and the encrypt, half each; the
    /// verify pass after them reports nothing.
    ///
    /// `shouldStopReencryption` is asked before the scratch directory is made, at
    /// every chunk of the decrypt and the encrypt, and around the verify; true
    /// removes the scratch directory and throws `MigrationReencryptionAbandoned`.
    static func reencryptToSeekable(sourceENC2: URL,
                                    mediaID: String,
                                    keyBytes: [UInt8],
                                    shouldStopReencryption: @escaping @Sendable () -> Bool = { false },
                                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws
        -> (url: URL, header: SeekableEncryptedHeader, scratchDirectory: URL) {
        guard !shouldStopReencryption() else { throw MigrationReencryptionAbandoned() }
        let scratchDir = try MigrationReencryptScratch.makeDirectory()
        do {
            let plaintextURL = scratchDir.appendingPathComponent("\(mediaID).plain")
            defer { try? FileManager.default.removeItem(at: plaintextURL) }
            func stopIfRequested() throws {
                if shouldStopReencryption() { throw MigrationReencryptionAbandoned() }
            }

            let encrypted = EncryptedMedia(source: .url(sourceENC2), mediaType: .video, id: mediaID)
            let handler = SecretFileHandler(keyBytes: keyBytes, source: encrypted, targetURL: plaintextURL)
            // The decrypt stops at its next chunk once cancelled.
            let decrypt = Task { try await handler.decryptToURL() }
            let decryptProgress = handler.progress.sink { fraction in
                progress(fraction * 0.5)
                if shouldStopReencryption() { decrypt.cancel() }
            }
            do {
                _ = try await withTaskCancellationHandler {
                    try await decrypt.value
                } onCancel: {
                    decrypt.cancel()
                }
            } catch {
                decryptProgress.cancel()
                try stopIfRequested()
                throw error
            }
            decryptProgress.cancel()
            try stopIfRequested()

            let metadata = try? await EncryptedMetadataHandler().readMetadata(from: sourceENC2, keyBytes: keyBytes)
            let metadataJSON = try metadata.map { try SeekableEncryptedFormat.encodeMetadata($0) }

            let destination = scratchDir.appendingPathComponent("\(mediaID).enc3")
            // Detached: the writer is synchronous and this manager is @MainActor — a
            // multi-GB encrypt must never run on the main thread.
            let header: SeekableEncryptedHeader
            do {
                header = try await Task.detached(priority: .userInitiated) {
                    try SeekableEncryptedWriter(keyBytes: keyBytes)
                        .encrypt(source: plaintextURL, destination: destination, metadata: metadataJSON,
                                 progress: { fraction in progress(0.5 + fraction * 0.5) },
                                 shouldStop: shouldStopReencryption)
                }.value
            } catch {
                try stopIfRequested()
                throw error
            }
            try afterReencryptWriteForTesting?(destination)
            try stopIfRequested()

            do {
                try await Task.detached(priority: .userInitiated) {
                    try await ReencryptVerifier.verify(enc3: destination,
                                                       plaintext: plaintextURL,
                                                       keyBytes: keyBytes,
                                                       writtenHeader: header,
                                                       metadata: metadataJSON)
                }.value
            } catch {
                printDebug("re-encrypt VERIFY FAILED mediaID=\(mediaID) — keeping the original: \(error)")
                throw error
            }
            try stopIfRequested()
            return (destination, header, scratchDir)
        } catch {
            MigrationReencryptScratch.release(scratchDir)
            throw error
        }
    }
}

// MARK: - CloudKit -> local

@MainActor
struct CloudKitToLocalStep: MigrationItemStep, DebugPrintable {

    /// Slows each download so a UI test can observe the run, mirroring the mock
    /// store's upload delay. Zero outside UI tests.
    static var downloadDelay: Duration = .zero

    /// Copies the record's ciphertext into the destination's file layout, fetching
    /// it if it is not in the blob cache, then verifies the copy against the size
    /// the record on the server holds. Previews
    /// need no copying — they live in the storage-agnostic global thumbnail
    /// directory.
    func transfer(at index: Int, in plan: inout MigrationPlan, context: MigrationRunContext) async throws {
        let item = plan.items[index]
        guard let destinationModel = context.destinationModel else {
            throw MigrationError.verificationFailed(recordName: item.recordName)
        }
        let destinationURL = destinationModel.driveURLForMedia(withID: item.mediaID, type: item.mediaType)

        // An interrupted download left no trustworthy bytes: start it again.
        if plan.items[index].state == .uploading {
            plan.items[index].state = .pending
        }

        if plan.items[index].state == .pending || plan.items[index].state == .failed {
            context.setPhase(.downloading, plan, item.mediaID)
            plan.items[index].state = .uploading
            plan.items[index].lastError = nil
            plan.items[index].verifiedSizeBytes = nil
            try await context.savePlan(plan)

            // A copy an earlier run left that still matches the record is this
            // item's, so it stays. Anything else there is replaced.
            if (try? await Self.localCopy(at: destinationURL, matchesRecordOf: item, store: context.store)) == true {
                printDebug("item kept existing local copy recordName=\(item.recordName)")
            } else {
                let cachedURL: URL
                do {
                    let report = context.reportTransferProgress
                    cachedURL = try await context.coordinator.ensureBlobLocal(recordName: item.recordName,
                                                                              albumID: context.cloudKitAlbumID) { fraction in
                        report(index, fraction)
                    }
                } catch CloudKitMediaStoreError.notFound {
                    // The record is gone from CloudKit, so there is nothing to move.
                    printDebug("item SKIPPED recordName=\(item.recordName) — record not found in CloudKit")
                    plan.items[index].state = .skipped
                    plan.items[index].lastError = "Record not found in CloudKit"
                    try await context.savePlan(plan)
                    return
                }
                if Self.downloadDelay > .zero {
                    try await Task.sleep(for: Self.downloadDelay)
                }
                try Self.placeCopy(of: cachedURL, at: destinationURL)
                printDebug("item downloaded recordName=\(item.recordName) bytes=\(destinationURL.fileSizeBytes() ?? -1)")
            }
            plan.items[index].state = .uploaded
            try await context.savePlan(plan)
        }

        if plan.items[index].state == .uploaded {
            context.setPhase(.verifying, plan, item.mediaID)
            // Checked against the record on the server, never against the cached
            // blob the copy was made from: a truncated cache entry agrees with the
            // truncated copy it produced. A record the server does not have is
            // checked against the capture's durable file when it is still waiting
            // in the upload queue; otherwise it proves nothing either way.
            let matches = try await Self.localCopy(at: destinationURL, matchesSourceOf: item, context: context)
            guard matches == true else {
                if matches == false {
                    // The cached blob is the likeliest source of a short copy. Evict
                    // it so the next attempt downloads the record again.
                    try? await context.coordinator.evictLocalCopy(recordName: item.recordName)
                }
                printDebug("item VERIFY FAILED recordName=\(item.recordName) destSize=\(destinationURL.fileSizeBytes() ?? -1) recordOnServer=\(matches != nil)")
                throw MigrationError.verificationFailed(recordName: item.recordName)
            }
            printDebug("item verified locally recordName=\(item.recordName)")
            plan.items[index].state = .verified
            plan.items[index].verifiedSizeBytes = destinationURL.fileSizeBytes()
            try await context.savePlan(plan)
        }
    }

    /// Brings home every not-yet-done item still waiting in this device's upload
    /// queue, before anything is downloaded. Each one's queue file is copied into
    /// the destination and verified byte for byte against it; the item is then
    /// checkpointed `verified` with its `movedOutOfUploadQueue`, and only after
    /// that is its queue entry cancelled, which deletes the queue file. A capture
    /// no longer queued is never sent by the uploader.
    ///
    /// An item checkpointed as moved whose entry is still queued (the app was
    /// killed before the cancel) only has its entry cancelled, once its copy still
    /// has the size it verified at. A copy that cannot be placed or does not match
    /// leaves the item as it was, for its transfer to retry. Returns the indices
    /// this pass moved and verified.
    func moveCapturesOutOfUploadQueue(in plan: inout MigrationPlan, context: MigrationRunContext) async throws -> Set<Int> {
        guard let destinationModel = context.destinationModel else { return [] }
        var moved = Set<Int>()
        for index in plan.items.indices where !plan.items[index].state.isDone {
            let item = plan.items[index]
            guard let queued = await context.uploadQueue.pendingItem(recordName: item.recordName) else { continue }
            let destinationURL = destinationModel.driveURLForMedia(withID: item.mediaID, type: item.mediaType)

            if item.state == .verified || item.state == .removalPending {
                guard item.movedOutOfUploadQueue != nil,
                      let verifiedSize = item.verifiedSizeBytes,
                      destinationURL.fileSizeBytes() == verifiedSize else { continue }
                await context.uploadQueue.cancel(recordName: item.recordName)
                printDebug("move out of upload queue: cancelled the entry of a capture already moved recordName=\(item.recordName)")
                continue
            }

            guard let queuedURL = await context.uploadQueue.pendingFileURL(recordName: item.recordName) else { continue }
            context.setPhase(.downloading, plan, item.mediaID)
            do {
                try Self.placeCopy(of: queuedURL, at: destinationURL)
            } catch {
                printDebug("move out of upload queue COPY FAILED recordName=\(item.recordName) — left for the transfer: \(error)")
                continue
            }
            guard FileManager.default.contentsEqual(atPath: destinationURL.path, andPath: queuedURL.path) else {
                printDebug("move out of upload queue VERIFY FAILED recordName=\(item.recordName) — the copy differs from the queue file, left for the transfer")
                continue
            }
            plan.items[index].state = .verified
            plan.items[index].lastError = nil
            plan.items[index].verifiedSizeBytes = destinationURL.fileSizeBytes()
            plan.items[index].movedOutOfUploadQueue = MigrationMovedCapture(chunkCount: queued.chunkCount)
            try await context.savePlan(plan)
            await context.uploadQueue.cancel(recordName: item.recordName)
            moved.insert(index)
            printDebug("move out of upload queue ok recordName=\(item.recordName) bytes=\(plan.items[index].verifiedSizeBytes ?? -1) chunkCount=\(queued.chunkCount)")
        }
        return moved
    }

    /// Puts a copy of `source` at `destination`. A file already there is only
    /// swapped out once the full copy exists beside it, so a copy that fails
    /// leaves it as it was.
    static func placeCopy(of source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.copyItem(at: source, to: destination)
            return
        }
        let staged = fileManager.temporaryDirectory
            .appendingPathComponent("migration-incoming-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staged)
        do {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    /// Whether the file at `url` is present and as long as the ciphertext the
    /// item's record holds. `nil` when the server has no such record, so there is
    /// nothing to compare against. A missing file is `false` without asking.
    static func localCopy(at url: URL,
                          matchesRecordOf item: MigrationItem,
                          store: CloudKitMediaStoring) async throws -> Bool? {
        guard let size = url.fileSizeBytes(), size > 0 else { return false }
        guard let metadata = try await store.fetchRecordMetadata(recordName: item.recordName) else { return nil }
        guard let expected = metadata.expectedCiphertextLength, expected == size else {
            printDebug("local copy MISMATCH recordName=\(item.recordName) local=\(size) record=\(metadata.expectedCiphertextLength.map(String.init) ?? "unknown")")
            return false
        }
        return true
    }

    /// Deletes the record. The verified local copy is the one the destination album
    /// reads, so this never removes the last copy. The item is `sourceDeleted` only
    /// once the server delete is confirmed; one left in the delete queue is
    /// `removalPending`, and a later run issues it again.
    func removeSource(at index: Int,
                      in plan: inout MigrationPlan,
                      verifiedThisRun: Bool,
                      context: MigrationRunContext) async throws {
        guard plan.items[index].state == .verified || plan.items[index].state == .removalPending else { return }
        let item = plan.items[index]
        // A cancel requested mid-item stops BEFORE the irreversible delete.
        if context.isCancelRequested() { throw CloudKitMediaStoreError.cancelled }
        // The local copy may have been deleted or damaged since it verified, even
        // earlier in this run, so it is checked before every record delete. One
        // verified in this run is compared with the size it had then, which needs
        // no request; an older verification is checked against the record again. A
        // copy that no longer matches goes back to download again. A record already
        // gone leaves nothing to compare against and nothing to lose by deleting.
        // The check runs under the removal phase, not `.verifying`: it is part of
        // removing this record, and on a resumed removal pass a phase flip per item
        // makes "Removing X of Y" flicker to "Verifying in iCloud", which describes
        // the opposite direction. A capture moved out of the upload queue is always compared with the size
        // it verified at: the queue file it was checked against is gone, and the
        // server has no record to compare with.
        context.setPhase(.removingRemoteCopy, plan, item.mediaID)
        var matches: Bool? = false
        if let destinationURL = context.destinationModel?.driveURLForMedia(withID: item.mediaID, type: item.mediaType) {
            if verifiedThisRun || item.movedOutOfUploadQueue != nil, let verifiedSize = item.verifiedSizeBytes {
                matches = destinationURL.fileSizeBytes() == verifiedSize
            } else {
                matches = try await Self.localCopy(at: destinationURL, matchesSourceOf: item, context: context)
            }
        }
        if matches == false {
            printDebug("item STALE VERIFICATION recordName=\(item.recordName) verifiedThisRun=\(verifiedThisRun) — local copy missing or no longer matches, downloading again")
            plan.items[index].state = .pending
            plan.items[index].verifiedSizeBytes = nil
            plan.items[index].lastError = "stale verification: local copy missing or does not match the record"
            try await context.savePlan(plan)
            return
        }
        let started = Date()
        let outcome: CloudKitRemoveOutcome
        if let moved = item.movedOutOfUploadQueue {
            // Removed as a pending item with the queue's chunk geometry: a save in
            // flight when its entry was cancelled may have landed since, with
            // or without its chunks, and removing a record that is not there is a
            // no-op.
            await context.uploadQueue.cancel(recordName: item.recordName)
            outcome = try await context.coordinator.remove(recordName: item.recordName,
                                                           albumID: context.cloudKitAlbumID,
                                                           wasPending: true,
                                                           pendingChunkCount: moved.chunkCount)
        } else if let queued = await context.uploadQueue.pendingItem(recordName: item.recordName) {
            // A capture still waiting to upload that was not moved out of the queue
            // has its durable file as the source copy. Its local copy is verified,
            // so the queue entry goes, and with it the upload that would otherwise
            // land in an album about to be deleted. One that reached the server in
            // the meantime is removed like any other record.
            let onServer = try await context.store.fetchRecordMetadata(recordName: item.recordName) != nil
            await context.uploadQueue.cancel(recordName: item.recordName)
            printDebug("item cancelled queued upload recordName=\(item.recordName) onServer=\(onServer)")
            outcome = try await context.coordinator.remove(recordName: item.recordName,
                                                           albumID: context.cloudKitAlbumID,
                                                           wasPending: !onServer,
                                                           pendingChunkCount: onServer ? 0 : queued.chunkCount)
        } else {
            outcome = try await context.coordinator.remove(recordName: item.recordName,
                                                           albumID: context.cloudKitAlbumID)
        }
        printDebug("item removed from CloudKit recordName=\(item.recordName) outcome=\(outcome) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        plan.items[index].state = outcome == .confirmed ? .sourceDeleted : .removalPending
        try await context.savePlan(plan)
    }

    /// Whether the file at `url` is a full copy of the item's source: the record on
    /// the server or, for a capture the server does not have yet, the durable file
    /// it waits in. `nil` when neither exists, so there is nothing to compare against.
    static func localCopy(at url: URL,
                          matchesSourceOf item: MigrationItem,
                          context: MigrationRunContext) async throws -> Bool? {
        if let matches = try await localCopy(at: url, matchesRecordOf: item, store: context.store) {
            return matches
        }
        guard let queuedURL = await context.uploadQueue.pendingFileURL(recordName: item.recordName) else { return nil }
        let matches = FileManager.default.contentsEqual(atPath: url.path, andPath: queuedURL.path)
        if !matches {
            printDebug("local copy MISMATCH recordName=\(item.recordName) — differs from the queued capture")
        }
        return matches
    }
}
