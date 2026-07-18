//
//  MockCloudKitMediaStore.swift
//  EncameraCoreTests
//
//  In-memory fake of the `CloudKitMediaStoring` seam for coordinator tests.
//

import Foundation
import CloudKit
@testable import EncameraCore

final class MockCloudKitMediaStore: CloudKitMediaStoring, @unchecked Sendable {

    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // Programmable
    var accountAvailableValue = true
    var changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
    var metadataToReturn: [CloudKitMediaMetadata] = []
    var blobContents = Data("ciphertext".utf8)
    var fetchBlobDelayNanos: UInt64 = 0
    var fetchBlobError: Error?
    var fetchChangesError: Error?
    var deleteError: Error?
    var uploadRefOverride: CloudKitMediaRef?

    // Recorded
    private var _fetchBlobCount = 0
    private var _fetchChangesCount = 0
    private var _registerSubscriptionCount = 0
    private var _tombstoneCalls: [String] = []
    private var _deleteCalls: [String] = []
    private var _uploadCalls: [String] = []
    private var _uploadedItems: [CloudKitMediaUpload] = []
    var uploadedItems: [CloudKitMediaUpload] { locked { _uploadedItems } }

    var fetchBlobCount: Int { locked { _fetchBlobCount } }
    var fetchChangesCount: Int { locked { _fetchChangesCount } }
    var registerSubscriptionCount: Int { locked { _registerSubscriptionCount } }
    var tombstoneCalls: [String] { locked { _tombstoneCalls } }
    var deleteCalls: [String] { locked { _deleteCalls } }
    var uploadCalls: [String] { locked { _uploadCalls } }

    var uploadErrorOnce: Error?
    /// Opt-in (default off, so existing coordinator tests are unaffected): when set,
    /// each successful `upload` is reflected back from `fetchMetadata`, so a migration
    /// verify step sees what it just uploaded — modeling server truth.
    var reflectUploadsInMetadata = false
    private var _reflected: [CloudKitMediaMetadata] = []
    func upload(_ item: CloudKitMediaUpload,
                progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        locked { _uploadCalls.append(item.mediaID); _uploadedItems.append(item) }
        if let error = uploadErrorOnce { uploadErrorOnce = nil; throw error }
        if reflectUploadsInMetadata {
            locked {
                _reflected.removeAll { $0.recordName == item.recordName }
                _reflected.append(CloudKitMediaMetadata(
                    recordName: item.recordName,
                    albumID: item.albumID,
                    mediaID: item.mediaID,
                    mediaType: item.mediaType,
                    createdAt: item.createdAt,
                    sizeBytes: item.sizeBytes,
                    creationDeviceID: "mock",
                    deletedAt: nil,
                    schemaVersion: item.schemaVersion,
                    recordChangeTag: "tag-upload"
                ))
            }
        }
        progress(1.0)
        return uploadRefOverride ?? CloudKitMediaRef(recordName: item.recordName, recordChangeTag: "tag-upload")
    }

    func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        locked { metadataToReturn + (reflectUploadsInMetadata ? _reflected : []) }
    }

    func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        locked { (metadataToReturn + (reflectUploadsInMetadata ? _reflected : []))
            .first { $0.recordName == recordName && $0.deletedAt == nil } }
    }

    func fetchBlob(recordName: String,
                   to destination: URL,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        locked { _fetchBlobCount += 1 }
        if fetchBlobDelayNanos > 0 { try? await Task.sleep(nanoseconds: fetchBlobDelayNanos) }
        if let fetchBlobError { throw fetchBlobError }
        try blobContents.write(to: destination)
        progress(1.0)
    }

    private(set) var fetchThumbnailCount = 0
    var fetchThumbnailWritesFile = true
    var fetchThumbnailError: Error?
    func fetchThumbnail(recordName: String, to destination: URL) async throws {
        locked { fetchThumbnailCount += 1 }
        if fetchThumbnailWritesFile { try blobContents.write(to: destination) }
        if let fetchThumbnailError { throw fetchThumbnailError }   // simulates a partial write then failure
    }

    func delete(recordName: String) async throws {
        locked { _deleteCalls.append(recordName) }
        if let deleteError { throw deleteError }
    }

    func tombstone(recordName: String) async throws {
        locked { _tombstoneCalls.append(recordName) }
    }

    // MARK: Albums (chunk 13)

    private var _albums: [String: CloudKitAlbumMetadata] = [:]
    private var _savedAlbumCalls: [CloudKitAlbumUpload] = []
    private var _tombstonedAlbumCalls: [String] = []
    var savedAlbumCalls: [CloudKitAlbumUpload] { locked { _savedAlbumCalls } }
    var tombstonedAlbumCalls: [String] { locked { _tombstonedAlbumCalls } }
    /// Seed album records as if they came from another device.
    func seedAlbum(_ album: CloudKitAlbumMetadata) { locked { _albums[album.albumID] = album } }

    func saveAlbum(_ album: CloudKitAlbumUpload) async throws {
        guard accountAvailableValue else { throw CloudKitMediaStoreError.accountUnavailable }
        locked {
            _savedAlbumCalls.append(album)
            _albums[album.albumID] = CloudKitAlbumMetadata(
                albumID: album.albumID, encName: album.encName, createdAt: album.createdAt,
                isHidden: album.isHidden, deletedAt: nil, schemaVersion: album.schemaVersion,
                recordChangeTag: "albumtag")
        }
    }

    private var _fetchAllAlbumsCount = 0
    var fetchAllAlbumsCount: Int { locked { _fetchAllAlbumsCount } }
    /// Awaited (when set) before returning, so a test can hold a sync pass open mid-run.
    var fetchAllAlbumsGate: (@Sendable () async -> Void)?

    func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] {
        locked { _fetchAllAlbumsCount += 1 }
        if let gate = fetchAllAlbumsGate { await gate() }
        return locked { Array(_albums.values) }
    }

    func tombstoneAlbum(albumID: String) async throws {
        locked {
            _tombstonedAlbumCalls.append(albumID)
            if let existing = _albums[albumID] {
                _albums[albumID] = CloudKitAlbumMetadata(
                    albumID: existing.albumID, encName: existing.encName, createdAt: existing.createdAt,
                    isHidden: existing.isHidden, deletedAt: Date(), schemaVersion: existing.schemaVersion,
                    recordChangeTag: existing.recordChangeTag)
            }
        }
    }

    var fetchChangesErrorOnce: Error?
    var fetchChangesDelayNanos: UInt64 = 0
    func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        locked { _fetchChangesCount += 1 }
        if fetchChangesDelayNanos > 0 { try? await Task.sleep(nanoseconds: fetchChangesDelayNanos) }
        if let error = fetchChangesErrorOnce { fetchChangesErrorOnce = nil; throw error }
        if let fetchChangesError { throw fetchChangesError }
        return changeSet
    }

    private(set) var committedTokenCount = 0
    private(set) var resetChangeTokenCount = 0
    private(set) var recreateZoneCount = 0
    var hasChangeTokenValue = false
    func loadChangeToken() async -> CKServerChangeToken? { nil }
    func hasChangeToken() async -> Bool { hasChangeTokenValue }
    func commitChangeToken(_ token: CKServerChangeToken?) async {
        locked { committedTokenCount += 1 }
    }
    func resetChangeToken() async { locked { resetChangeTokenCount += 1 } }
    func recreateZone() async throws { locked { recreateZoneCount += 1 } }

    private(set) var ensureZoneCalls = 0
    func ensureZoneExists() async throws {
        locked { ensureZoneCalls += 1 }
    }

    func registerZoneSubscription() async throws {
        guard accountAvailableValue else { return }
        locked { _registerSubscriptionCount += 1 }
    }

    func cancelAll() {}

    func accountAvailable() async -> Bool { accountAvailableValue }
}
