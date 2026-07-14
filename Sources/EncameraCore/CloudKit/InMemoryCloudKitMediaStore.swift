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
    }

    private let lock = NSLock()
    private var records: [String: Stored] = [:]
    private var albums: [String: CloudKitAlbumMetadata] = [:]
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public init() {}

    public func upload(_ item: CloudKitMediaUpload,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        let blob = (try? Data(contentsOf: item.encryptedFileURL)) ?? Data()
        let thumb = item.encryptedThumbURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let tag = "tag-\(item.recordName)"
        let metadata = CloudKitMediaMetadata(
            recordName: item.recordName, albumID: item.albumID, mediaID: item.mediaID,
            mediaType: item.mediaType, createdAt: item.createdAt, sizeBytes: item.sizeBytes,
            creationDeviceID: DeviceIdentity.current, deletedAt: nil,
            schemaVersion: item.schemaVersion, recordChangeTag: tag
        )
        // Keyed by recordName so a Live Photo's two components don't collide.
        locked { records[item.recordName] = Stored(metadata: metadata, blob: blob, thumbnail: thumb) }
        progress(1.0)
        return CloudKitMediaRef(recordName: item.recordName, recordChangeTag: tag)
    }

    public func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        locked { records.values.map { $0.metadata }.filter { $0.albumID == albumID && $0.deletedAt == nil } }
    }

    public func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        locked { records[recordName].map { $0.metadata }.flatMap { $0.deletedAt == nil ? $0 : nil } }
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
        locked { records[recordName] = nil }
    }

    public func tombstone(recordName: String) async throws {
        locked {
            if var stored = records[recordName] {
                stored.metadata = CloudKitMediaMetadata(
                    recordName: stored.metadata.recordName, albumID: stored.metadata.albumID,
                    mediaID: stored.metadata.mediaID, mediaType: stored.metadata.mediaType,
                    createdAt: stored.metadata.createdAt, sizeBytes: stored.metadata.sizeBytes,
                    creationDeviceID: stored.metadata.creationDeviceID, deletedAt: Date(),
                    schemaVersion: stored.metadata.schemaVersion, recordChangeTag: stored.metadata.recordChangeTag
                )
                records[recordName] = stored
            }
        }
    }

    // MARK: Albums (chunk 13)

    public func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        let tag = "albumtag-\(album.albumID)"
        locked {
            albums[album.albumID] = CloudKitAlbumMetadata(
                albumID: album.albumID, encName: album.encName, createdAt: album.createdAt,
                isHidden: album.isHidden, deletedAt: nil, schemaVersion: album.schemaVersion,
                recordChangeTag: tag
            )
        }
    }

    public func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        locked { Array(albums.values) }
    }

    public func tombstoneAlbum(albumID: String) async throws {
        locked {
            if let existing = albums[albumID] {
                albums[albumID] = CloudKitAlbumMetadata(
                    albumID: existing.albumID, encName: existing.encName, createdAt: existing.createdAt,
                    isHidden: existing.isHidden, deletedAt: Date(), schemaVersion: existing.schemaVersion,
                    recordChangeTag: existing.recordChangeTag
                )
            }
        }
    }

    public func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        let all = locked { Array(records.values) }
        let changed = all.filter { $0.metadata.deletedAt == nil }.map { $0.metadata }
        let deleted = all.filter { $0.metadata.deletedAt != nil }.map { $0.metadata.recordName }
        return CloudKitChangeSet(changed: changed, deleted: deleted, token: nil, moreComing: false)
    }

    public func loadChangeToken() async -> CKServerChangeToken? { nil }

    public func hasChangeToken() async -> Bool { false }

    public func commitChangeToken(_ token: CKServerChangeToken?) async {}

    public func resetChangeToken() async {}

    public func recreateZone() async throws {}

    public func ensureZoneExists() async throws {}

    public func registerZoneSubscription() async throws {}

    public func cancelAll() {}

    public func accountAvailable() async -> Bool { true }
}
