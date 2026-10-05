//
//  InMemoryCloudKitMediaStore.swift
//  EncameraCore
//
//  A deterministic, in-memory `CloudKitMediaStoring` for UI tests (`-CloudKitMockMode`)
//  and offline verification. Stores ciphertext blobs and index fields in memory —
//  never touches the network or an iCloud account.
//

import Foundation
import CloudKit

public final class InMemoryCloudKitMediaStore: CloudKitMediaStoring, @unchecked Sendable {

    private struct Stored {
        var metadata: CloudKitMediaMetadata
        var blob: Data
        var thumbnail: Data
        var keyFingerprint: String
    }

    private let lock = NSLock()
    private var records: [String: Stored] = [:]
    private var albums: [String: CloudKitAlbumMetadata] = [:]
    /// Deletions the change feed still has to report. The real zone reports a
    /// deleted record once, by id and type; a fake that just drops the entry would
    /// let a delete vanish without any consumer ever hearing about it.
    private var deletedAlbumIDs: [String] = []
    private var deletedRecordNames: [String] = []
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// Artificial per-upload delay, for UI tests that need a migration to stay in
    /// flight long enough to observe. Defaults to zero, so every existing caller —
    /// including all the unit tests — is unaffected.
    public var uploadDelay: Duration = .zero

    /// Album IDs whose next upload throws `quotaExceeded` instead of storing,
    /// once each. Lets a UI test halt a migration on a recoverable failure and
    /// resume it against the same store; see `failNextUpload(forAlbumID:)`.
    private var albumIDsFailingNextUpload: Set<String> = []

    /// Transport for chunked blobs. When an upload carries `chunkCount > 0` the
    /// ciphertext is split into chunks via this store instead of being held as a
    /// monolithic blob — mirroring what `CloudKitMediaStore` does in production.
    /// Defaults to `InMemoryChunkedBlobStore()` so the mock is self-contained;
    /// callers that need the same instance reachable from a coordinator should
    /// inject a shared one.
    public let chunkStore: ChunkedBlobStoring

    public init(chunkStore: ChunkedBlobStoring = InMemoryChunkedBlobStore()) {
        self.chunkStore = chunkStore
    }

    public init(uploadDelay: Duration, chunkStore: ChunkedBlobStoring = InMemoryChunkedBlobStore()) {
        self.uploadDelay = uploadDelay
        self.chunkStore = chunkStore
    }

    /// A store that survives a relaunch: it loads `url` if present and rewrites it
    /// after every change, so a UI test can kill the app mid-run and find the zone
    /// as it was. Chunked payloads live in `chunkStore` and are not persisted.
    public init(persistingTo url: URL,
                uploadDelay: Duration = .zero,
                chunkStore: ChunkedBlobStoring = InMemoryChunkedBlobStore()) {
        self.uploadDelay = uploadDelay
        self.chunkStore = chunkStore
        self.persistenceURL = url
        if let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot.restore(into: self)
        }
    }

    private var persistenceURL: URL?

    /// Rejects the next upload for `albumID` with `CloudKitMediaStoreError.quotaExceeded`
    /// — the recoverable, run-halting classification — then behaves normally.
    public func failNextUpload(forAlbumID albumID: String) {
        locked { _ = albumIDsFailingNextUpload.insert(albumID) }
    }

    /// Album-name matchers whose next upload throws `quotaExceeded`, once each. Each
    /// is asked about the `encName` of the album record the upload's album id names.
    private var encryptedNameMatchersFailingNextUpload: [(String) -> Bool] = []

    /// Like `failNextUpload(forAlbumID:)`, for an album whose CloudKit id is not known
    /// yet: rejects the next upload into the album whose record's `encName` satisfies
    /// `matches`.
    public func failNextUpload(toAlbumWhoseEncryptedName matches: @escaping (String) -> Bool) {
        locked { encryptedNameMatchersFailingNextUpload.append(matches) }
    }

    /// Record names whose next upload throws `quotaExceeded`, once each.
    private var recordNamesFailingNextUpload: Set<String> = []

    /// Rejects the next upload of the record named `recordName` with
    /// `CloudKitMediaStoreError.quotaExceeded`, then behaves normally.
    public func failNextUpload(recordName: String) {
        locked { _ = recordNamesFailingNextUpload.insert(recordName) }
    }

    /// When set, every `reassignAlbum` throws `retry(after:)` and moves nothing, as
    /// if the device had lost its connection. Driven by `-CloudKitMockFailReassign`.
    public var failsEveryReassign = false

    /// When set, every `confirmAlbum` throws `retry(after:)`, as if the device had
    /// lost its connection. Driven by `-CloudKitMockFailConfirm`.
    public var failsEveryConfirm = false

    public func confirmAlbum(recordName: String) async throws -> String? {
        if failsEveryConfirm { throw CloudKitMediaStoreError.retry(after: 1) }
        return try await fetchRecordMetadata(recordName: recordName)?.albumID
    }

    private func consumeUploadFailure(forAlbumID albumID: String) -> Bool {
        locked {
            if albumIDsFailingNextUpload.remove(albumID) != nil { return true }
            guard let encName = albums[albumID]?.encName,
                  let index = encryptedNameMatchersFailingNextUpload.firstIndex(where: { $0(encName) }) else {
                return false
            }
            encryptedNameMatchersFailingNextUpload.remove(at: index)
            return true
        }
    }

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        if locked({ recordNamesFailingNextUpload.remove(item.recordName) != nil })
            || consumeUploadFailure(forAlbumID: item.descriptor.albumID) {
            throw CloudKitMediaStoreError.quotaExceeded
        }
        if uploadDelay > .zero {
            try await Task.sleep(for: uploadDelay)
        }

        let blob: Data
        var encHeader: Data?
        if item.chunkCount > 0 {
            if item.existingChunks == .overwrite, locked({ records[item.recordName] != nil }) {
                throw CloudKitMediaStoreError.conflict(serverRecord: nil)
            }
            try await chunkStore.uploadChunks(enc3FileURL: item.encryptedFileURL,
                                              mediaRecordName: item.recordName,
                                              existingChunks: item.existingChunks,
                                              progress: progress)
            blob = Data()
            // The real record carries its header, the only source of a chunked
            // record's ciphertext length.
            encHeader = try? SeekableEncryptedHeader.read(fromFileAt: item.encryptedFileURL).bytes
        } else {
            blob = (try? Data(contentsOf: item.encryptedFileURL)) ?? Data()
        }

        let thumb = item.encryptedThumbURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let tag = "tag-\(item.recordName)"
        let metadata = CloudKitMediaMetadata(descriptor: item.descriptor,
                                             creationDeviceID: DeviceIdentity.current,
                                             schemaVersion: item.schemaVersion,
                                             recordChangeTag: tag,
                                             encHeader: encHeader)
        // Keyed by recordName so a Live Photo's two components don't collide.
        locked {
            records[item.recordName] = Stored(metadata: metadata,
                                              blob: blob,
                                              thumbnail: thumb,
                                              keyFingerprint: item.keyFingerprint)
        }
        persist()
        progress(1.0)
        return CloudKitMediaRef(recordName: item.recordName, recordChangeTag: tag)
    }

    /// Seeds an album and `mediaCount` live media records directly, as if another
    /// device had written them. Without this the mock binds an EMPTY zone, so a UI
    /// test that stubs a probe census of N is driving a delete over nothing: the
    /// sweep deletes zero records and passes exactly as it would against a
    /// coordinator that deleted nothing at all.
    ///
    /// `includeAlbumRecord: false` seeds the media with NO album record — the media
    /// whose `EncAlbum` another device hard-deleted, or that a stale query index has
    /// not caught up with. `fetchAllAlbums` then enumerates nothing while the census
    /// still counts the records, which is the shape of the vacuous-success bug.
    public func seedRecords(albumID: String,
                            mediaCount: Int,
                            keyFingerprint: String = "seeded-fingerprint",
                            includeAlbumRecord: Bool = true) {
        locked {
            if includeAlbumRecord {
                albums[albumID] = CloudKitAlbumMetadata(
                    albumID: albumID, encName: "enc-\(albumID)", createdAt: Date(),
                    isHidden: false,
                    schemaVersion: CloudKitSchema.currentSchemaVersion,
                    keyFingerprint: keyFingerprint,
                    recordChangeTag: "albumtag-\(albumID)"
                )
            }
            for index in 0..<mediaCount {
                let recordName = "\(albumID)-seeded-\(index)"
                let descriptor = CloudKitMediaRecordDescriptor(
                    albumID: albumID, mediaID: recordName, recordName: recordName,
                    mediaType: .photo, createdAt: Date(), sizeBytes: 1, keyFingerprint: ""
                )
                let metadata = CloudKitMediaMetadata(descriptor: descriptor,
                                                     creationDeviceID: "seeded-device",
                                                     schemaVersion: CloudKitSchema.currentSchemaVersion,
                                                     recordChangeTag: "tag-\(recordName)")
                records[recordName] = Stored(metadata: metadata,
                                             blob: Data(),
                                             thumbnail: Data(),
                                             keyFingerprint: keyFingerprint)
            }
        }
        persist()
    }

    /// Record names the zone still holds live, so a test can assert what a delete
    /// actually removed rather than inferring it from navigation.
    public var liveRecordNames: [String] {
        locked { records.values.map(\.metadata.recordName).sorted() }
    }

    public func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        locked { records.values.map { $0.metadata }.filter { $0.albumID == albumID } }
    }

    public func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        locked { records[recordName]?.metadata }
    }

    public func fetchBlob(recordName: String,
                          to destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let stored = locked({ records[recordName] }) else { throw CloudKitMediaStoreError.notFound }
        try stored.blob.write(to: destination)
        progress(1.0)
    }

    public func fetchThumbnail(recordName: String, to destination: URL) async throws {
        guard let stored = locked({ records[recordName] }) else { throw CloudKitMediaStoreError.notFound }
        try stored.thumbnail.write(to: destination)
    }

    public func delete(recordName: String) async throws {
        locked {
            guard records.removeValue(forKey: recordName) != nil else { return }
            deletedRecordNames.append(recordName)
        }
        persist()
    }

    // MARK: Albums

    /// When set, every `saveAlbum` throws it.
    public var saveAlbumError: Error?

    public func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        if let saveAlbumError { throw saveAlbumError }
        let tag = "albumtag-\(album.albumID)"
        locked {
            let migrationInProgress = album.migrationInProgress ?? albums[album.albumID]?.migrationInProgress ?? false
            albums[album.albumID] = CloudKitAlbumMetadata(
                albumID: album.albumID, encName: album.encName, createdAt: album.createdAt,
                isHidden: album.isHidden, schemaVersion: album.schemaVersion,
                keyFingerprint: album.keyFingerprint.isEmpty ? nil : album.keyFingerprint,
                recordChangeTag: tag, coverMediaID: album.coverMediaID,
                migrationInProgress: migrationInProgress
            )
        }
        persist()
    }

    /// Album ids the query index has not caught up with: `fetchAllAlbums` leaves
    /// them out while `fetchAlbum` still finds them, as a just-saved record behaves
    /// on the server.
    public var albumIDsMissingFromQuery: Set<String> = []

    public func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        locked { albums.values.filter { !albumIDsMissingFromQuery.contains($0.albumID) } }
    }

    public func fetchAlbum(albumID: String) async throws -> CloudKitAlbumMetadata? {
        locked { albums[albumID] }
    }

    /// Always `.counted`: an in-memory store knows its own contents exactly, so an
    /// empty result really is an empty zone.
    public func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus {
        locked {
            var counts: [String: Int] = [:]
            for stored in records.values {
                guard !stored.keyFingerprint.isEmpty else { continue }
                counts[stored.keyFingerprint, default: 0] += 1
            }
            return .counted(mediaCount: records.count, fingerprints: counts)
        }
    }

    public func deleteAlbum(albumID: String) async throws {
        locked {
            guard albums.removeValue(forKey: albumID) != nil else { return }
            deletedAlbumIDs.append(albumID)
            for (recordName, stored) in records where stored.metadata.albumID == albumID {
                records[recordName] = nil
                deletedRecordNames.append(recordName)
            }
        }
        persist()
    }

    public func reassignAlbum(recordNames: [String], toAlbumID: String) async throws -> [String] {
        if failsEveryReassign { throw CloudKitMediaStoreError.retry(after: 1) }
        defer { persist() }
        return locked {
            var notFound: [String] = []
            // Every save gives the record a new change tag, as the server does,
            // including across a relaunch of a persisted zone.
            let saveTag = UUID().uuidString
            for name in recordNames {
                guard var stored = records[name] else {
                    notFound.append(name)
                    continue
                }
                let oldDesc = stored.metadata.descriptor
                let newDesc = CloudKitMediaRecordDescriptor(
                    albumID: toAlbumID,
                    mediaID: oldDesc.mediaID,
                    recordName: oldDesc.recordName,
                    mediaType: oldDesc.mediaType,
                    createdAt: oldDesc.createdAt,
                    sizeBytes: oldDesc.sizeBytes,
                    keyFingerprint: oldDesc.keyFingerprint,
                    chunkCount: oldDesc.chunkCount,
                    plaintextLength: oldDesc.plaintextLength
                )
                stored.metadata = CloudKitMediaMetadata(
                    descriptor: newDesc,
                    creationDeviceID: stored.metadata.creationDeviceID,
                    schemaVersion: stored.metadata.schemaVersion,
                    recordChangeTag: "reassign-\(saveTag)-\(name)"
                )
                records[name] = stored
            }
            return notFound
        }
    }

    public func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        let (all, albumsNow, goneAlbums, goneRecords) = locked {
            (Array(records.values), Array(albums.values), deletedAlbumIDs, deletedRecordNames)
        }
        return CloudKitChangeSet(changed: all.map { $0.metadata },
                                 deleted: goneRecords,
                                 changedAlbums: albumsNow,
                                 deletedAlbumIDs: goneAlbums,
                                 token: nil,
                                 moreComing: false)
    }

    public func loadChangeToken() async -> CKServerChangeToken? { nil }

    public func hasChangeToken() async -> Bool { false }

    public func commitChangeToken(_ token: CKServerChangeToken?) async {}

    public func resetChangeToken() async {}

    public func recreateZone() async throws {}

    public func ensureZoneExists() async throws {}

    public func registerZoneSubscription() async throws {}

    public func cancelAll() {}

    /// What `accountAvailable()` answers. Clear it to stand in for a device
    /// signed out of iCloud.
    public var isAccountAvailable = true

    public func accountAvailable() async -> Bool { isAccountAvailable }

    // MARK: - Persistence

    private func persist() {
        guard let persistenceURL else { return }
        let snapshot = locked { Snapshot(records: Array(records.values), albums: Array(albums.values),
                                         deletedAlbumIDs: deletedAlbumIDs, deletedRecordNames: deletedRecordNames) }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private struct Snapshot: Codable {
        struct Record: Codable {
            let descriptor: CloudKitMediaRecordDescriptor
            let creationDeviceID: String
            let schemaVersion: Int64
            let recordChangeTag: String?
            let encHeader: Data?
            let blob: Data
            let thumbnail: Data
            let keyFingerprint: String
        }

        struct AlbumRecord: Codable {
            let albumID: String
            let encName: String
            let createdAt: Date
            let isHidden: Bool
            let schemaVersion: Int64
            let keyFingerprint: String?
            let recordChangeTag: String?
            let coverMediaID: String?
            let migrationInProgress: Bool?
        }

        let records: [Record]
        let albums: [AlbumRecord]
        let deletedAlbumIDs: [String]
        let deletedRecordNames: [String]

        init(records: [Stored], albums: [CloudKitAlbumMetadata], deletedAlbumIDs: [String], deletedRecordNames: [String]) {
            self.records = records.map { stored in
                Record(descriptor: stored.metadata.descriptor,
                       creationDeviceID: stored.metadata.creationDeviceID,
                       schemaVersion: stored.metadata.schemaVersion,
                       recordChangeTag: stored.metadata.recordChangeTag,
                       encHeader: stored.metadata.encHeader,
                       blob: stored.blob, thumbnail: stored.thumbnail,
                       keyFingerprint: stored.keyFingerprint)
            }
            self.albums = albums.map {
                AlbumRecord(albumID: $0.albumID, encName: $0.encName, createdAt: $0.createdAt,
                            isHidden: $0.isHidden, schemaVersion: $0.schemaVersion,
                            keyFingerprint: $0.keyFingerprint, recordChangeTag: $0.recordChangeTag,
                            coverMediaID: $0.coverMediaID, migrationInProgress: $0.migrationInProgress)
            }
            self.deletedAlbumIDs = deletedAlbumIDs
            self.deletedRecordNames = deletedRecordNames
        }

        func restore(into store: InMemoryCloudKitMediaStore) {
            store.locked {
                for record in records {
                    let metadata = CloudKitMediaMetadata(descriptor: record.descriptor,
                                                         creationDeviceID: record.creationDeviceID,
                                                         schemaVersion: record.schemaVersion,
                                                         recordChangeTag: record.recordChangeTag,
                                                         encHeader: record.encHeader)
                    store.records[record.descriptor.recordName] = Stored(metadata: metadata, blob: record.blob,
                                                              thumbnail: record.thumbnail,
                                                              keyFingerprint: record.keyFingerprint)
                }
                for album in albums {
                    store.albums[album.albumID] = CloudKitAlbumMetadata(
                        albumID: album.albumID, encName: album.encName, createdAt: album.createdAt,
                        isHidden: album.isHidden, schemaVersion: album.schemaVersion,
                        keyFingerprint: album.keyFingerprint, recordChangeTag: album.recordChangeTag,
                        coverMediaID: album.coverMediaID, migrationInProgress: album.migrationInProgress ?? false)
                }
                store.deletedAlbumIDs = deletedAlbumIDs
                store.deletedRecordNames = deletedRecordNames
            }
        }
    }
}
