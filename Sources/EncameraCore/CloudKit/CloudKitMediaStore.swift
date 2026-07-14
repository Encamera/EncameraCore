//
//  CloudKitMediaStore.swift
//  EncameraCore
//
//  The concrete Option-A record store: one `EncMedia` record per media item
//  carrying the index fields plus the eager thumbnail and lazy blob assets.
//  All CloudKit I/O goes through an injected `CloudKitDatabaseAdapter`, and the
//  account gate / change token / long-lived recovery state live in app-group
//  defaults. See plans/cloudkit-migration/02-cloudkit-media-store.md.
//

import Foundation
import CloudKit

public final class CloudKitMediaStore: CloudKitMediaStoring {

    private let container: CloudKitContainer
    private let adapter: CloudKitDatabaseAdapter
    private let defaults: UserDefaults
    private let zoneID: CKRecordZone.ID

    /// Per-namespace change-token key. The zone is shared across albums, but each
    /// album keeps its own independent cursor into the zone — otherwise syncing one
    /// album would advance the token for all the others and they'd miss changes.
    private let tokenKey: String
    private let longLivedMapKey = "cloudkit_longlived_ops_v1"
    /// Keyed by container id for the same reason as `CloudKitContainer`'s
    /// zone-created flag: the subscription lives in a specific container, so a
    /// flag set for one container must not suppress registration in another.
    private let subscriptionCreatedKey = "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID
    private let zoneSubscriptionID = "EncameraZoneSubscription"

    private let mapLock = NSLock()

    /// Index (non-asset) fields, used as `desiredKeys` for the cheap metadata sync.
    private static let metadataKeys: [CKRecord.FieldKey] = [
        CloudKitSchema.EncMedia.albumID,
        CloudKitSchema.EncMedia.mediaID,
        CloudKitSchema.EncMedia.mediaType,
        CloudKitSchema.EncMedia.createdAt,
        CloudKitSchema.EncMedia.sizeBytes,
        CloudKitSchema.EncMedia.creationDevice,
        CloudKitSchema.EncMedia.deletedAt,
        CloudKitSchema.EncMedia.schemaVersion
    ]

    public init(container: CloudKitContainer = .shared,
                adapter: CloudKitDatabaseAdapter? = nil,
                defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard,
                tokenNamespace: String = "",
                recoverOnInit: Bool = true) {
        self.container = container
        self.defaults = defaults
        self.zoneID = container.zoneID
        self.tokenKey = tokenNamespace.isEmpty
            ? "cloudkit_zone_change_token_v1"
            : "cloudkit_zone_change_token_v1_\(tokenNamespace)"
        self.adapter = adapter ?? CKDatabaseAdapter(container: container.container,
                                                    database: container.privateDB)
        if recoverOnInit {
            Task { [weak self] in await self?.recoverLongLivedOperations() }
        }
    }

    // MARK: - Account

    public func accountAvailable() async -> Bool {
        await container.isCloudKitAvailable()
    }

    // MARK: - Upload

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }

        let record = makeRecord(for: item)
        // Key long-lived tracking by recordName: a Live Photo's two components share
        // a mediaID but are distinct records, so keying by mediaID would collide.
        let recordName = item.recordName
        do {
            let saved = try await adapter.save(
                records: [record],
                savePolicy: .ifServerRecordUnchanged,
                isLongLived: true,
                perRecordProgress: { _, fraction in progress(fraction) },
                operationIDHandler: { [weak self] operationID in
                    if let operationID = operationID { self?.rememberLongLived(recordName: recordName, operationID: operationID) }
                }
            )
            forgetLongLived(recordName: recordName)
            let result = saved.first ?? record
            return CloudKitMediaRef(recordName: result.recordID.recordName,
                                    recordChangeTag: result.recordChangeTag)
        } catch {
            forgetLongLived(recordName: recordName)
            throw mapAndRecord(error)
        }
    }

    private func makeRecord(for item: CloudKitMediaUpload) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitSchema.EncMedia.recordType, recordID: recordID)
        record[CloudKitSchema.EncMedia.albumID] = item.albumID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaID] = item.mediaID as CKRecordValue
        record[CloudKitSchema.EncMedia.mediaType] = Int64(item.mediaType.rawValue) as CKRecordValue
        record[CloudKitSchema.EncMedia.createdAt] = item.createdAt as CKRecordValue
        record[CloudKitSchema.EncMedia.sizeBytes] = item.sizeBytes as CKRecordValue
        record[CloudKitSchema.EncMedia.creationDevice] = DeviceIdentity.currentID(defaults: defaults) as CKRecordValue
        record[CloudKitSchema.EncMedia.schemaVersion] = item.schemaVersion as CKRecordValue
        if let thumbURL = item.encryptedThumbURL {
            record[CloudKitSchema.EncMedia.encThumbnail] = CKAsset(fileURL: thumbURL)
        }
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: item.encryptedFileURL)
        // Relational link to the owning EncAlbum (record name == albumID hash). The
        // `.deleteSelf` action cascades a media delete when the album is deleted; the
        // same reference is set as `parent` for future record sharing. We do NOT need
        // the album record to exist first — CloudKit stores the reference regardless.
        let albumRecordID = CKRecord.ID(recordName: item.albumID, zoneID: zoneID)
        record[CloudKitSchema.EncMedia.albumRef] = CKRecord.Reference(recordID: albumRecordID, action: .deleteSelf)
        record.parent = CKRecord.Reference(recordID: albumRecordID, action: .none)
        return record
    }

    // MARK: - Albums (chunk 13)

    public func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        guard await accountAvailable() else { throw CloudKitMediaStoreError.accountUnavailable }
        let recordID = CKRecord.ID(recordName: album.albumID, zoneID: zoneID)
        do {
            // Fetch-then-update so a re-save preserves the change tag and revives a
            // previously tombstoned album; build fresh when the record is absent.
            let existing = try await adapter.fetch(recordIDs: [recordID],
                                                   desiredKeys: nil,
                                                   perRecordProgress: { _, _ in })
            let record = existing[recordID] ?? CKRecord(recordType: CloudKitSchema.EncAlbum.recordType, recordID: recordID)
            record[CloudKitSchema.EncAlbum.encName] = album.encName as CKRecordValue
            record[CloudKitSchema.EncAlbum.createdAt] = album.createdAt as CKRecordValue
            record[CloudKitSchema.EncAlbum.isHidden] = Int64(album.isHidden ? 1 : 0) as CKRecordValue
            record[CloudKitSchema.EncAlbum.deletedAt] = nil          // revive on re-create
            record[CloudKitSchema.EncAlbum.schemaVersion] = album.schemaVersion as CKRecordValue
            _ = try await adapter.save(records: [record],
                                       savePolicy: .ifServerRecordUnchanged,
                                       isLongLived: false,
                                       perRecordProgress: { _, _ in },
                                       operationIDHandler: { _ in })
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        do {
            let records = try await adapter.query(recordType: CloudKitSchema.EncAlbum.recordType,
                                                  predicate: NSPredicate(value: true),
                                                  zoneID: zoneID,
                                                  desiredKeys: nil)
            return records.compactMap(albumMetadata(from:))
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func tombstoneAlbum(albumID: String) async throws {
        let recordID = CKRecord.ID(recordName: albumID, zoneID: zoneID)
        do {
            let fetched = try await adapter.fetch(recordIDs: [recordID],
                                                  desiredKeys: nil,
                                                  perRecordProgress: { _, _ in })
            guard let record = fetched[recordID] else { return }   // already gone — nothing to tombstone
            record[CloudKitSchema.EncAlbum.deletedAt] = Date() as CKRecordValue
            _ = try await adapter.save(records: [record],
                                       savePolicy: .ifServerRecordUnchanged,
                                       isLongLived: false,
                                       perRecordProgress: { _, _ in },
                                       operationIDHandler: { _ in })
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
        let deletedAt = record[CloudKitSchema.EncAlbum.deletedAt] as? Date
        let schemaVersion = (record[CloudKitSchema.EncAlbum.schemaVersion] as? Int64) ?? CloudKitSchema.currentSchemaVersion
        return CloudKitAlbumMetadata(albumID: record.recordID.recordName,
                                     encName: encName,
                                     createdAt: createdAt,
                                     isHidden: isHidden,
                                     deletedAt: deletedAt,
                                     schemaVersion: schemaVersion,
                                     recordChangeTag: record.recordChangeTag)
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
                                                  desiredKeys: desiredKeys)
            // Tombstoned records are filtered client-side (server nil-predicates are unreliable).
            return records.compactMap(metadata(from:)).filter { $0.deletedAt == nil }
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
            guard let record = fetched[recordID],
                  let meta = metadata(from: record),
                  meta.deletedAt == nil else {
                return nil
            }
            return meta
        } catch {
            throw mapAndRecord(error)
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
        } catch let error as CloudKitMediaStoreError {
            throw error
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Delete / tombstone

    public func delete(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            // Single op removes the record and, with it, both assets — atomically.
            _ = try await adapter.delete(recordIDs: [recordID])
        } catch {
            throw mapAndRecord(error)
        }
    }

    public func tombstone(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            let fetched = try await adapter.fetch(recordIDs: [recordID],
                                                  desiredKeys: Self.metadataKeys,
                                                  perRecordProgress: { _, _ in })
            guard let record = fetched[recordID] else { throw CloudKitMediaStoreError.notFound }
            record[CloudKitSchema.EncMedia.deletedAt] = Date() as CKRecordValue
            _ = try await adapter.save(records: [record],
                                       savePolicy: .ifServerRecordUnchanged,
                                       isLongLived: false,
                                       perRecordProgress: { _, _ in },
                                       operationIDHandler: { _ in })
        } catch let error as CloudKitMediaStoreError {
            throw error
        } catch {
            throw mapAndRecord(error)
        }
    }

    // MARK: - Delta sync

    public func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        do {
            // Pure: fetch from exactly `token`; the caller commits the new token only
            // after the changes are durably applied.
            let result = try await adapter.fetchZoneChanges(zoneID: zoneID,
                                                            since: token,
                                                            desiredKeys: Self.metadataKeys)
            let changed = result.changed.compactMap(metadata(from:))
            return CloudKitChangeSet(changed: changed,
                                     deleted: result.deletedRecordNames,
                                     token: result.token,
                                     moreComing: result.moreComing)
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
        guard await accountAvailable() else { return }     // skip when no account (per research)
        if defaults.bool(forKey: subscriptionCreatedKey) { return }

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: zoneSubscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true   // silent push
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

    // MARK: - Long-lived recovery

    /// Re-attach any long-lived operations (our persisted map ∪ CloudKit's own list)
    /// so an upload interrupted by app termination resumes and reports completion.
    public func recoverLongLivedOperations() async {
        var ids = Set(loadLongLivedMap().values)
        for id in await adapter.allLongLivedOperationIDs() { ids.insert(id) }
        for id in ids {
            await adapter.reattachLongLivedOperation(id: id)
        }
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
        let deletedAt = record[CloudKitSchema.EncMedia.deletedAt] as? Date
        let schemaVersion = (record[CloudKitSchema.EncMedia.schemaVersion] as? Int64) ?? CloudKitSchema.currentSchemaVersion

        return CloudKitMediaMetadata(recordName: record.recordID.recordName,
                                     albumID: albumID,
                                     mediaID: mediaID,
                                     mediaType: mediaType,
                                     createdAt: createdAt,
                                     sizeBytes: sizeBytes,
                                     creationDeviceID: creationDeviceID,
                                     deletedAt: deletedAt,
                                     schemaVersion: schemaVersion,
                                     recordChangeTag: record.recordChangeTag)
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

    // MARK: - Long-lived map persistence

    private func loadLongLivedMap() -> [String: String] {
        mapLock.lock(); defer { mapLock.unlock() }
        return (defaults.dictionary(forKey: longLivedMapKey) as? [String: String]) ?? [:]
    }

    private func rememberLongLived(recordName: String, operationID: CKOperation.ID) {
        mapLock.lock(); defer { mapLock.unlock() }
        var map = (defaults.dictionary(forKey: longLivedMapKey) as? [String: String]) ?? [:]
        map[recordName] = operationID
        defaults.set(map, forKey: longLivedMapKey)
    }

    private func forgetLongLived(recordName: String) {
        mapLock.lock(); defer { mapLock.unlock() }
        var map = (defaults.dictionary(forKey: longLivedMapKey) as? [String: String]) ?? [:]
        map.removeValue(forKey: recordName)
        defaults.set(map, forKey: longLivedMapKey)
    }
}
