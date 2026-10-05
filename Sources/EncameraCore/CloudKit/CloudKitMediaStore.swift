//
//  CloudKitMediaStore.swift
//  EncameraCore
//
//  The concrete Option-A record store: one `EncMedia` record per media item
//  carrying the index fields plus the eager thumbnail and lazy blob assets.
//  All CloudKit I/O goes through an injected `CloudKitDatabaseAdapter`, and the
//  account gate / change token live in app-group defaults.
//  See plans/cloudkit-migration/02-cloudkit-media-store.md.
//

import Foundation
import CloudKit

public final class CloudKitMediaStore: CloudKitMediaStoring, DebugPrintable {

    private let container: CloudKitContainer
    private let adapter: CloudKitDatabaseAdapter
    private let defaults: UserDefaults
    private let zoneID: CKRecordZone.ID

    /// Per-namespace change-token key. The zone is shared across albums, but each
    /// album keeps its own independent cursor into the zone — otherwise syncing one
    /// album would advance the token for all the others and they'd miss changes.
    private let tokenKey: String
    /// Written only by builds that issued uploads as long-lived operations; read now
    /// solely so it can be deleted. See `purgeLegacyLongLivedState()`.
    private let longLivedMapKey = "cloudkit_longlived_ops_v1"
    /// Keyed by container id for the same reason as `CloudKitContainer`'s
    /// zone-created flag: the subscription lives in a specific container, so a
    /// flag set for one container must not suppress registration in another.
    private let subscriptionCreatedKey = "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID
    private let zoneSubscriptionID = "EncameraZoneSubscription"

    /// Index (non-asset) fields, used as `desiredKeys` for the cheap metadata sync.
    /// Internal rather than private so a test can assert every list names the
    /// fingerprint: a fetch that omits it returns records the mapper cannot build, and
    /// the media vanishes from the album rather than failing visibly.
    ///
    /// The same requirement covers the three chunked-blob fields. CloudKit returns
    /// only the keys named here, and `metadata(from:)` reads an absent `chunkCount`
    /// as "monolithic" — so omitting them turns every chunked video into a record
    /// whose `encBlob` asset is missing: unplayable, and undeletable without
    /// orphaning its chunks. `encHeader` is framing, not payload; the lazy-blob
    /// guarantee is about `encBlob`, which must never appear in any of these lists.
    static let metadataKeys: [CKRecord.FieldKey] = [
        CloudKitSchema.EncMedia.albumID,
        CloudKitSchema.EncMedia.mediaID,
        CloudKitSchema.EncMedia.mediaType,
        CloudKitSchema.EncMedia.createdAt,
        CloudKitSchema.EncMedia.sizeBytes,
        CloudKitSchema.EncMedia.creationDevice,
        CloudKitSchema.EncMedia.schemaVersion,
        CloudKitSchema.EncMedia.keyFingerprint,
        CloudKitSchema.EncMedia.chunkCount,
        CloudKitSchema.EncMedia.plaintextLength,
        CloudKitSchema.EncMedia.encHeader
    ]

    /// `desiredKeys` for the zone change feed, which carries BOTH record types.
    /// The parameter is zone-wide, not per-type, so the album fields have to be
    /// named here or an `EncAlbum` record arrives with none of them set and is
    /// discarded as unmappable. All small scalars — never add `encBlob`, which is
    /// the whole point of the lazy-blob guarantee.
    static let changeFeedKeys: [CKRecord.FieldKey] = metadataKeys + [
        CloudKitSchema.EncAlbum.encName,
        CloudKitSchema.EncAlbum.isHidden,
        CloudKitSchema.EncAlbum.keyFingerprint,
        CloudKitSchema.EncAlbum.coverMediaRef
    ]

    /// Transport for chunked blobs (`EncBlobChunk` records in the blob zone).
    /// Lazy so constructing a store for tests never touches the real container
    /// unless a chunked upload actually happens.
    private let makeChunkStore: () -> ChunkedBlobStoring
    private lazy var chunkStore: ChunkedBlobStoring = makeChunkStore()

    public init(container: CloudKitContainer = .shared,
                adapter: CloudKitDatabaseAdapter? = nil,
                defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard,
                tokenNamespace: String = "",
                chunkStore: ChunkedBlobStoring? = nil) {
        self.container = container
        self.defaults = defaults
        self.zoneID = container.zoneID
        self.tokenKey = tokenNamespace.isEmpty
            ? "cloudkit_zone_change_token_v1"
            : "cloudkit_zone_change_token_v1_\(tokenNamespace)"
        self.adapter = adapter ?? CKDatabaseAdapter(database: container.privateDB)
        self.makeChunkStore = { chunkStore ?? CloudKitChunkedBlobStore(container: container) }
        purgeLegacyLongLivedState()
    }

    // MARK: - Account

    public func accountAvailable() async -> Bool {
        await container.isCloudKitAvailable()
    }

    // MARK: - Upload

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }
        if CloudKitStoreTestHooks.consumeUploadFailure() {
            printDebug("upload FAILED recordName=\(item.recordName) — quotaExceeded injected by -CloudKitFailUploadAfter")
            throw CloudKitMediaStoreError.quotaExceeded
        }

        // Upload the preview from a private snapshot, never the live file.
        let snapshot = item.encryptedThumbURL.flatMap { Self.snapshotForUpload($0) }
        defer {
            if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
        }

        let record = makeRecord(for: item, thumbnailURL: snapshot ?? item.encryptedThumbURL)
        let recordName = item.recordName
        printDebug("upload start recordName=\(recordName) albumID=\(item.albumID) mediaType=\(item.mediaType) sizeBytes=\(item.sizeBytes) chunkCount=\(item.chunkCount) zone=\(zoneID.zoneName) hasThumb=\(item.encryptedThumbURL != nil)")

        // A chunked item's payload goes to the blob zone FIRST; the `EncMedia`
        // save below is then the commit point (`makeRecord` gave it the header
        // fields and no `encBlob`). Until it lands, a partial chunk upload reads
        // as "not chunked yet" — never as a truncated video. Computed chunk names
        // make a retry idempotent, and `existingChunks` says whether it may keep
        // the chunks an earlier attempt saved.
        if item.chunkCount > 0 {
            // Rewriting the chunks of a committed record would leave its header
            // describing an encryption its chunks no longer hold. A committed record
            // is already whole, so report it as the conflict the commit would have
            // hit, and let the caller verify it.
            if item.existingChunks == .overwrite {
                let committed: Bool
                do {
                    committed = try await recordExists(recordName: recordName)
                } catch {
                    let mapped = mapAndRecord(error)
                    printDebug("upload overwrite check FAILED recordName=\(recordName) mapped=\(mapped) raw=\(error)")
                    throw mapped
                }
                if committed {
                    printDebug("upload REFUSED recordName=\(recordName) — overwrite requested but the record is already committed")
                    throw CloudKitMediaStoreError.conflict(serverRecord: nil)
                }
            }
            do {
                try await chunkStore.uploadChunks(enc3FileURL: item.encryptedFileURL,
                                                  mediaRecordName: item.recordName,
                                                  existingChunks: item.existingChunks,
                                                  progress: progress)
            } catch ChunkedBlobError.accountUnavailable {
                throw CloudKitMediaStoreError.accountUnavailable
            } catch {
                let mapped = mapAndRecord(error)
                printDebug("upload chunks FAILED recordName=\(recordName) mapped=\(mapped) raw=\(error)")
                throw mapped
            }
        }

        do {
            let saved = try await adapter.save(
                records: [record],
                savePolicy: .ifServerRecordUnchanged,
                perRecordProgress: { _, fraction in progress(fraction) }
            )
            if saved.isEmpty {
                printDebug("upload WARNING recordName=\(recordName) save returned no records; reporting the unconfirmed local record")
            }
            let result = saved.first ?? record
            printDebug("upload ok recordName=\(result.recordID.recordName) changeTag=\(result.recordChangeTag ?? "nil") confirmedByServer=\(!saved.isEmpty)")
            return CloudKitMediaRef(recordName: result.recordID.recordName,
                                    recordChangeTag: result.recordChangeTag)
        } catch {
            let mapped = mapAndRecord(error)
            printDebug("upload FAILED recordName=\(recordName) mapped=\(mapped) raw=\(error)")
            throw mapped
        }
    }

    /// Whether the `EncMedia` record is on the server. Fetch by id is strongly
    /// consistent, a missing record is absent from the result, and no field is
    /// asked for.
    private func recordExists(recordName: String) async throws -> Bool {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let found = try await adapter.fetch(recordIDs: [recordID],
                                            desiredKeys: [],
                                            perRecordProgress: { _, _ in })
        return found[recordID] != nil
    }

    /// Copies `source` somewhere only this upload knows about. Returns nil if the
    /// copy fails, in which case the caller falls back to the live file — an
    /// upload that might hit the modified-asset race is still better than
    /// silently dropping the thumbnail.
    private static func snapshotForUpload(_ source: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckupload-\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            printDebug("snapshotForUpload FAILED source=\(source.lastPathComponent) raw=\(error) — uploading the live file instead")
            return nil
        }
    }

    private func makeRecord(for item: CloudKitMediaUpload, thumbnailURL: URL?) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID)
        apply(item, thumbnailURL: thumbnailURL, to: record)
        return record
    }

    /// Writes this upload's fields onto a brand-new record.
    private func apply(_ item: CloudKitMediaUpload, thumbnailURL: URL?, to record: CKRecord) {
        record[CloudKitSchema.EncMedia.albumID] = item.albumID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = item.mediaID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(item.mediaType.rawValue) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = item.createdAt as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = item.sizeBytes as CKRecordValue
        record[CloudKitSchema.EncMedia.creationDevice] = DeviceIdentity.currentID(defaults: defaults) as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = item.schemaVersion as CKRecordValue
        record[CloudKitSchema.EncMedia.keyFingerprint] = item.keyFingerprint as CKRecordValue
        if let thumbnailURL {
            record[CloudKitSchema.EncMedia.encThumbnail] = CKAsset(fileURL: thumbnailURL)
        }
        if item.chunkCount > 0, let headerData = try? SeekableEncryptedHeader.read(fromFileAt: item.encryptedFileURL).bytes {
            record[CloudKitSchema.EncMedia.encHeader] = headerData as CKRecordValue
            record[CloudKitSchema.EncMedia.chunkCount] = Int64(item.chunkCount) as CKRecordValue
            record[CloudKitSchema.EncMedia.plaintextLength] = item.plaintextLength as CKRecordValue
        } else {
            record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: item.encryptedFileURL)
        }
        let albumRecordID = CKRecord.ID(recordName: item.albumID, zoneID: zoneID)
        record[CloudKitSchema.EncMedia.albumRef] = CKRecord.Reference(recordID: albumRecordID, action: .deleteSelf)
        record.parent = CKRecord.Reference(recordID: albumRecordID, action: .none)
    }

    // MARK: - Albums

    public func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        if CloudKitStoreTestHooks.failAlbumSaves { throw CloudKitMediaStoreError.retry(after: 1) }
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }
        let recordID = CKRecord.ID(recordName: album.albumID, zoneID: zoneID)
        do {
            let existing = try await adapter.fetch(recordIDs: [recordID],
                                                   desiredKeys: nil,
                                                   perRecordProgress: { _, _ in })
            let record = existing[recordID] ?? CKRecord(recordType: CloudKitSchema.EncAlbum.recordType, recordID: recordID)
            record[CloudKitSchema.EncAlbum.encName] = album.encName as CKRecordValue
            record[CloudKitSchema.EncAlbum.createdAt] = album.createdAt as CKRecordValue
            record[CloudKitSchema.EncAlbum.isHidden] = Int64(album.isHidden ? 1 : 0) as CKRecordValue
            record[CloudKitSchema.EncAlbum.schemaVersion] = album.schemaVersion as CKRecordValue
            record[CloudKitSchema.EncAlbum.keyFingerprint] = album.keyFingerprint as CKRecordValue
            if let migrationInProgress = album.migrationInProgress {
                record[CloudKitSchema.EncAlbum.migrationInProgress] = Int64(migrationInProgress ? 1 : 0) as CKRecordValue
            }
            if let coverMediaID = album.coverMediaID {
                let coverRecordName = MediaRecordName.componentRecordName(mediaID: coverMediaID, type: .photo)
                let coverRecordID = CKRecord.ID(recordName: coverRecordName, zoneID: zoneID)
                record[CloudKitSchema.EncAlbum.coverMediaRef] = CKRecord.Reference(recordID: coverRecordID, action: .none)
            } else {
                record[CloudKitSchema.EncAlbum.coverMediaRef] = nil
            }
            _ = try await adapter.save(records: [record],
                                       savePolicy: .ifServerRecordUnchanged,
                                       perRecordProgress: { _, _ in })
        } catch {
            throw mapAndRecord(error)
        }
    }

    /// Re-parents `EncMedia` records to another album: rewrites `albumID`, `albumRef`
    /// and `parent`. Assets are untouched — `.ifServerRecordUnchanged` sends only
    /// changed keys to the server. A `CKRecord` fetched with a `desiredKeys` subset
    /// can be modified and saved: unfetched fields (including blob assets) are
    /// preserved. Confirmed: WWDC14 "Advanced CloudKit" documents that CKRecord
    /// tracks changes locally and only the changed fields are transmitted on save;
    /// partial records save normally. Both `.ifServerRecordUnchanged` and
    /// `.changedKeys` policies send only changed keys; the difference is conflict
    /// detection.
    public func reassignAlbum(recordNames: [String], toAlbumID: String) async throws -> [String] {
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }
        // CloudKit caps a single CKModifyRecordsOperation at 400 records.
        let batchSize = 400
        var notFound: [String] = []

        for batch in recordNames.chunked(into: batchSize) {
            let recordIDs = batch.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            do {
                // Fetch with only albumID — .ifServerRecordUnchanged sends only changed
                // keys, so unfetched assets (encBlob, encThumbnail) are preserved on the
                // server.
                let fetched = try await adapter.fetch(recordIDs: recordIDs,
                                                      desiredKeys: [CloudKitSchema.EncMedia.albumID],
                                                      perRecordProgress: { _, _ in })
                var toSave: [CKRecord] = []
                for recordID in recordIDs {
                    guard let record = fetched[recordID] else {
                        notFound.append(recordID.recordName)
                        continue
                    }
                    record[CloudKitSchema.EncMedia.albumID] = toAlbumID as CKRecordValue
                    let albumRecordID = CKRecord.ID(recordName: toAlbumID, zoneID: zoneID)
                    record[CloudKitSchema.EncMedia.albumRef] = CKRecord.Reference(recordID: albumRecordID, action: .deleteSelf)
                    record.parent = CKRecord.Reference(recordID: albumRecordID, action: .none)
                    toSave.append(record)
                }
                if !toSave.isEmpty {
                    _ = try await adapter.save(records: toSave,
                                               savePolicy: .ifServerRecordUnchanged,
                                               perRecordProgress: { _, _ in })
                }
            } catch {
                throw mapAndRecord(error)
            }
        }
        return notFound
    }

    public func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        do {
            let records = try await adapter.query(recordType: CloudKitSchema.EncAlbum.recordType,
                                                  predicate: NSPredicate(value: true),
                                                  zoneID: zoneID,
                                                  desiredKeys: nil)
            return records.compactMap(albumMetadata(from:))
        } catch {
            let mapped = mapAndRecord(error)
            if case .zoneNotFound = mapped {
                printDebug("fetchAllAlbums zoneNotFound zone=\(zoneID.zoneName) container=\(CloudKitSchema.containerID) — reporting no albums; a zone that does not exist holds none")
                return []
            }
            throw mapped
        }
    }

    /// A missing record is absent from the fetch result. A `notFound` error, bare
    /// or as every entry of a partial failure, means the same thing. Any other
    /// failure, a missing zone included, is thrown: the server did not answer.
    public func fetchAlbum(albumID: String) async throws -> CloudKitAlbumMetadata? {
        let recordID = CKRecord.ID(recordName: albumID, zoneID: zoneID)
        let fetched: [CKRecord.ID: CKRecord]
        do {
            fetched = try await adapter.fetch(recordIDs: [recordID],
                                              desiredKeys: nil,
                                              perRecordProgress: { _, _ in })
        } catch {
            let mapped = mapAndRecord(error)
            if Self.isNotFound(mapped) {
                printDebug("fetchAlbum MISS albumID=\(albumID) — server reported no such record")
                return nil
            }
            printDebug("fetchAlbum FAILED albumID=\(albumID) mapped=\(mapped)")
            throw mapped
        }
        guard let record = fetched[recordID] else {
            printDebug("fetchAlbum MISS albumID=\(albumID) — no record returned by fetch-by-id")
            return nil
        }
        guard let metadata = albumMetadata(from: record) else {
            // The record exists, so this must not read as "gone".
            printDebug("fetchAlbum UNREADABLE albumID=\(albumID) keys=\(record.allKeys())")
            throw CloudKitMediaStoreError.underlying(CKError(.internalError))
        }
        printDebug("fetchAlbum hit albumID=\(albumID)")
        return metadata
    }

    private static func isNotFound(_ error: CloudKitMediaStoreError) -> Bool {
        switch error {
        case .notFound:
            return true
        case .partial(let failed):
            return !failed.isEmpty && failed.values.allSatisfy {
                if case .notFound = mapCKError($0) { return true } else { return false }
            }
        default:
            return false
        }
    }

    /// See `CloudKitMediaStoring.fetchFingerprintCensus()`. Asset-free by
    /// construction: `desiredKeys` names only the fingerprint, so neither `encBlob`
    /// nor `encThumbnail` is ever transferred.
    ///
    /// The predicate filters on `createdAt` (matching every record — uploads always
    /// set it) instead of `NSPredicate(value: true)` deliberately: a `true` predicate
    /// resolves through the system `recordName` index, which the deploy runbook never
    /// prescribes for `EncMedia`, whereas `createdAt` is Queryable in every deployed
    /// container. `keyFingerprint` itself needs no index — it is only retrieved via
    /// `desiredKeys`, never filtered on.
    public func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus {
        let desiredKeys = [CloudKitSchema.EncMedia.keyFingerprint]
        do {
            let records = try await adapter.query(recordType: CloudKitSchema.EncMedia.recordType,
                                                  predicate: NSPredicate(format: "%K > %@",
                                                                         CloudKitSchema.EncMedia.createdAt,
                                                                         Date.distantPast as NSDate),
                                                  zoneID: zoneID,
                                                  desiredKeys: desiredKeys)
            var counts: [String: Int] = [:]
            for record in records {
                guard let fingerprint = record[CloudKitSchema.EncMedia.keyFingerprint] as? String,
                      !fingerprint.isEmpty else { continue }
                counts[fingerprint, default: 0] += 1
            }
            printDebug("fetchFingerprintCensus ok records=\(records.count) fingerprints=\(counts.count)")
            return .counted(mediaCount: records.count, fingerprints: counts)
        } catch {
            let mapped = mapAndRecord(error)
            if Self.isSchemaNotReady(error) {
                printDebug("fetchFingerprintCensus degraded — schema cannot answer the census query yet; index unavailable (raw=\(error))")
                return .indexUnavailable
            }
            throw mapped
        }
    }

    /// True when the failure means "the server schema does not know this field/type
    /// yet" rather than a real I/O failure. CloudKit reports an unindexed field as
    /// `.invalidArguments` and an unknown record type as `.unknownItem`.
    private static func isSchemaNotReady(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .invalidArguments || ckError.code == .unknownItem
    }

    public func deleteAlbum(albumID: String) async throws {
        if CloudKitStoreTestHooks.failDeletes { throw CloudKitMediaStoreError.retry(after: 1) }
        let recordID = CKRecord.ID(recordName: albumID, zoneID: zoneID)
        do {
            _ = try await adapter.delete(recordIDs: [recordID])
        } catch {
            throw mapAndRecord(error)
        }
    }

    private func albumMetadata(from record: CKRecord) -> CloudKitAlbumMetadata? {
        guard let encName = record[CloudKitSchema.EncAlbum.encName] as? String,
              let createdAt = record[CloudKitSchema.EncAlbum.createdAt] as? Date else {
            return nil
        }
        let isHidden = ((record[CloudKitSchema.EncAlbum.isHidden] as? Int64) ?? 0) != 0
        let schemaVersion = (record[CloudKitSchema.EncAlbum.schemaVersion] as? Int64) ?? CloudKitSchema.currentSchemaVersion
        let keyFingerprint = record[CloudKitSchema.EncAlbum.keyFingerprint] as? String
        let migrationInProgress = ((record[CloudKitSchema.EncAlbum.migrationInProgress] as? Int64) ?? 0) != 0
        let coverMediaID: String?
        if let ref = record[CloudKitSchema.EncAlbum.coverMediaRef] as? CKRecord.Reference {
            coverMediaID = MediaRecordName.mediaID(from: ref.recordID.recordName)
        } else {
            coverMediaID = nil
        }
        return CloudKitAlbumMetadata(albumID: record.recordID.recordName,
                                     encName: encName,
                                     createdAt: createdAt,
                                     isHidden: isHidden,
                                     schemaVersion: schemaVersion,
                                     keyFingerprint: keyFingerprint,
                                     recordChangeTag: record.recordChangeTag,
                                     coverMediaID: coverMediaID,
                                     migrationInProgress: migrationInProgress)
    }

    // MARK: - Metadata sync (asset-free, optional eager thumbnail)

    public func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        var desiredKeys = Self.metadataKeys
        if includeThumbnail { desiredKeys.append(CloudKitSchema.EncMedia.encThumbnail) }
        // Note: never request `encBlob` here — that is the lazy-fetch guarantee.

        let predicate = NSPredicate(format: "%K == %@", CloudKitSchema.EncMedia.albumID, albumID)
        do {
            let records = try await adapter.query(recordType: CloudKitSchema.EncMedia.recordType,
                                                  predicate: predicate,
                                                  zoneID: zoneID,
                                                  desiredKeys: desiredKeys,
                                                  qualityOfService: includeThumbnail ? .userInteractive : .userInitiated)
            return records.compactMap(metadata(from:))
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            // Fetch-by-record-ID is strongly consistent: a record saved moments ago is
            // visible here, unlike the query in `fetchMetadata`. A missing record is
            // simply absent from the result (the per-record API does not fail the op).
            let fetched = try await adapter.fetch(recordIDs: [recordID],
                                                  desiredKeys: Self.metadataKeys,
                                                  perRecordProgress: { _, _ in })
            guard let record = fetched[recordID] else {
                printDebug("fetchRecordMetadata MISS recordName=\(recordName) zone=\(zoneID.zoneName) — no record returned by fetch-by-id")
                return nil
            }
            guard let meta = metadata(from: record) else {
                printDebug("fetchRecordMetadata MISS recordName=\(recordName) — record exists but required fields are absent (albumID/mediaID/createdAt); keys present: \(record.allKeys())")
                return nil
            }
            printDebug("fetchRecordMetadata hit recordName=\(recordName) sizeBytes=\(meta.sizeBytes) changeTag=\(meta.recordChangeTag ?? "nil")")
            return meta
        } catch {
            let mapped = mapAndRecord(error)
            printDebug("fetchRecordMetadata FAILED recordName=\(recordName) mapped=\(mapped) raw=\(error)")
            throw mapped
        }
    }

    // MARK: - Lazy asset fetches

    public func fetchBlob(recordName: String,
                          to destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        try await fetchAsset(recordName: recordName,
                             assetKey: CloudKitSchema.EncMedia.encBlob,
                             to: destination,
                             progress: progress)
    }

    public func fetchThumbnail(recordName: String, to destination: URL) async throws {
        try await fetchAsset(recordName: recordName,
                             assetKey: CloudKitSchema.EncMedia.encThumbnail,
                             to: destination,
                             progress: { _ in })
    }

    private func fetchAsset(recordName: String,
                            assetKey: CKRecord.FieldKey,
                            to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            let records = try await adapter.fetch(recordIDs: [recordID],
                                                  desiredKeys: [assetKey],
                                                  qualityOfService: .userInteractive,
                                                  perRecordProgress: { _, fraction in progress(fraction) })
            guard let record = records[recordID],
                  let asset = record[assetKey] as? CKAsset,
                  let sourceURL = asset.fileURL else {
                throw CloudKitMediaStoreError.notFound
            }
            // CloudKit owns the temp URL and may delete it — copy out before returning.
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            CKDatabaseAdapter.discardSnapshot(at: sourceURL)
        } catch let error as CloudKitMediaStoreError {
            throw error
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Delete

    public func delete(recordName: String) async throws {
        if CloudKitStoreTestHooks.failDeletes { throw CloudKitMediaStoreError.retry(after: 1) }
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            _ = try await adapter.delete(recordIDs: [recordID])
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Delta sync

    public func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        do {
            let result = try await adapter.fetchZoneChanges(zoneID: zoneID,
                                                            since: token,
                                                            desiredKeys: Self.changeFeedKeys)
            var changed: [CloudKitMediaMetadata] = []
            var changedAlbums: [CloudKitAlbumMetadata] = []
            for record in result.changed {
                switch record.recordType {
                case CloudKitSchema.EncMedia.recordType:
                    if let meta = metadata(from: record) { changed.append(meta) }
                case CloudKitSchema.EncAlbum.recordType:
                    if let meta = albumMetadata(from: record) { changedAlbums.append(meta) }
                default:
                    printDebug("fetchChanges skip recordName=\(record.recordID.recordName) unknownType=\(record.recordType)")
                }
            }

            var deleted: [String] = []
            var deletedAlbumIDs: [String] = []
            for record in result.deleted {
                switch record.recordType {
                case CloudKitSchema.EncAlbum.recordType: deletedAlbumIDs.append(record.recordName)
                default: deleted.append(record.recordName)
                }
            }

            return CloudKitChangeSet(changed: changed,
                                     deleted: deleted,
                                     changedAlbums: changedAlbums,
                                     deletedAlbumIDs: deletedAlbumIDs,
                                     token: result.token,
                                     moreComing: result.moreComing,
                                     snapshotComplete: result.token != nil)
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func loadChangeToken() async -> CKServerChangeToken? {
        loadToken()
    }

    public func hasChangeToken() async -> Bool {
        defaults.data(forKey: tokenKey) != nil
    }

    public func commitChangeToken(_ token: CKServerChangeToken?) async {
        guard let token else { return }
        saveToken(token)
    }

    public func resetChangeToken() async {
        defaults.removeObject(forKey: tokenKey)
    }

    public func recreateZone() async throws {
        container.resetZoneCreatedFlag()
        try await container.ensureZoneExists()
    }

    // MARK: - Zone provisioning

    public func ensureZoneExists() async throws {
        try await container.ensureZoneExists()
    }

    // MARK: - Push subscription

    public func registerZoneSubscription() async throws {
        guard await accountAvailable() else { return }
        if defaults.bool(forKey: subscriptionCreatedKey) { return }

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: zoneSubscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        do {
            try await adapter.saveSubscription(subscription)
            defaults.set(true, forKey: subscriptionCreatedKey)
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Error mapping

    /// Maps a raw error and, when it reports the zone as gone (deleted in
    /// Settings > iCloud, account switched or wiped), invalidates the persisted
    /// zone-created and subscription flags — otherwise `ensureZoneExists()` and
    /// `registerZoneSubscription()` no-op on stale state forever and CloudKit
    /// storage stays broken until app data is cleared.
    private func mapAndRecord(_ error: Error) -> CloudKitMediaStoreError {
        let mapped = mapCKError(error)
        if case .zoneNotFound = mapped {
            container.resetZoneCreatedFlag()
            defaults.removeObject(forKey: subscriptionCreatedKey)
        }
        return mapped
    }

    // MARK: - Cancellation

    public func cancelAll() {
        adapter.cancelAll()
    }

    // MARK: - Legacy long-lived state

    /// Drops the operation-ID map older builds persisted for long-lived uploads.
    func purgeLegacyLongLivedState() {
        guard defaults.object(forKey: longLivedMapKey) != nil else { return }
        printDebug("purgeLegacyLongLivedState clearing \(longLivedMapKey)")
        defaults.removeObject(forKey: longLivedMapKey)
    }

    // MARK: - Record <-> metadata mapping

    private func metadata(from record: CKRecord) -> CloudKitMediaMetadata? {
        guard let albumID = record[CloudKitSchema.EncMedia.albumID] as? String,
              let mediaID = record[CloudKitSchema.EncMedia.mediaID] as? String,
              let createdAt = record[CloudKitSchema.EncMedia.createdAt] as? Date else {
            return nil
        }
        let rawType = (record[CloudKitSchema.EncMedia.mediaType] as? Int64).map { Int($0) } ?? MediaType.unknown.rawValue
        let mediaType = MediaType(rawValue: rawType) ?? .unknown
        let sizeBytes = (record[CloudKitSchema.EncMedia.sizeBytes] as? Int64) ?? 0
        let creationDeviceID = (record[CloudKitSchema.EncMedia.creationDevice] as? String) ?? ""
        let schemaVersion = (record[CloudKitSchema.EncMedia.schemaVersion] as? Int64) ?? CloudKitSchema.currentSchemaVersion
        let keyFingerprint = (record[CloudKitSchema.EncMedia.keyFingerprint] as? String) ?? ""
        // Absent means monolithic — every record written before chunked storage.
        let chunkCount = (record[CloudKitSchema.EncMedia.chunkCount] as? Int64).map(Int.init) ?? 0
        let plaintextLength = (record[CloudKitSchema.EncMedia.plaintextLength] as? Int64) ?? 0
        let encHeader = record[CloudKitSchema.EncMedia.encHeader] as? Data

        let descriptor = CloudKitMediaRecordDescriptor(albumID: albumID,
                                                       mediaID: mediaID,
                                                       recordName: record.recordID.recordName,
                                                       mediaType: mediaType,
                                                       createdAt: createdAt,
                                                       sizeBytes: sizeBytes,
                                                       keyFingerprint: keyFingerprint,
                                                       chunkCount: chunkCount,
                                                       plaintextLength: plaintextLength)
        return CloudKitMediaMetadata(descriptor: descriptor,
                                     creationDeviceID: creationDeviceID,
                                     schemaVersion: schemaVersion,
                                     recordChangeTag: record.recordChangeTag,
                                     encHeader: encHeader)
    }

    // MARK: - Token persistence

    private func loadToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: tokenKey)
    }

}
