import XCTest
import Sodium
@testable import EncameraCore

final class AlbumManagerChunkOrphanTests: XCTestCase {

    private let testKey = PrivateKey(name: "test", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    private func makeCloudKitAlbum() -> Album {
        Album(name: "ChunkOrphanAlbum", storageOption: .cloudKit, creationDate: Date(), key: testKey,
              albumID: UUID().uuidString)
    }

    /// When a record has been moved to a different album, `deleteCloudKitAlbumRecord`
    /// must skip its chunk reclaim — those chunks now belong to the other album.
    func testLocalAlbumDeleteSkipsChunkReclaimForRecordsThatMovedAway() async throws {
        let store = MockCloudKitMediaStore()
        // Seed a chunked member that `fetchMetadata` will return for the old album.
        let movedRecord = CloudKitMediaMetadata(
            descriptor: CloudKitMediaRecordDescriptor(
                albumID: "different-album-hash",
                mediaID: "media-1",
                recordName: "moved-record#0",
                mediaType: .photo,
                createdAt: Date(),
                sizeBytes: 1024,
                keyFingerprint: "fp",
                chunkCount: 3
            ),
            creationDeviceID: "mock",
            schemaVersion: CloudKitSchema.currentSchemaVersion,
            recordChangeTag: "tag"
        )
        store.metadataToReturn = [movedRecord]

        let previousMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        defer { CloudKitStoreProvider.makeStore = previousMakeStore }

        let keyManager = DemoKeyManager()
        let manager = AlbumManager(keyManager: keyManager)
        let album = makeCloudKitAlbum()

        manager.delete(album: album)

        // Wait for the async Task inside deleteCloudKitAlbumRecord to finish.
        let deadline = Date().addingTimeInterval(5)
        while store.fetchMetadataCalls.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.fetchMetadataCalls.isEmpty,
                       "deleteCloudKitAlbumRecord must enumerate members")

        // Wait for the confirmAlbum (fetchRecordMetadata) call.
        let confirmDeadline = Date().addingTimeInterval(5)
        while store.fetchRecordMetadataCalls.isEmpty, Date() < confirmDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.fetchRecordMetadataCalls, ["moved-record#0"],
                       "confirmAlbum must be called for each chunked member")

        // Give time for any chunk-reclaim that should NOT happen.
        try await Task.sleep(nanoseconds: 200_000_000)

        // The record's albumID was "different-album-hash", not the album being
        // deleted, so its chunks must NOT be reclaimed.
        let queue = CloudKitMediaDeleteQueue()
        let pending = queue.pending()
        XCTAssertFalse(pending.contains("moved-record#0"),
                       "Chunks of a record that moved to another album must NOT be enqueued for deletion")

        // Clean up the album delete queue entry.
        if let hash = album.albumID {
            CloudKitAlbumDeleteQueue().remove(hash)
        }
    }

    /// When `fetchMetadata` throws (offline, rate-limited), `deleteCloudKitAlbumRecord`
    /// must NOT proceed to `store.deleteAlbum`. If it did, the `.deleteSelf` cascade
    /// would destroy every `EncMedia` record while the chunk records — which live in a
    /// separate zone with no references — remain unqueued and permanently orphaned.
    /// The album must stay in the delete queue so the reconciler retries the whole
    /// sequence on its next pass.
    func testDeleteAbortedWhenChunkEnumerationFails() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchMetadataError = NSError(domain: "CKErrorDomain", code: 1, userInfo: nil)

        let previousMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        defer { CloudKitStoreProvider.makeStore = previousMakeStore }

        let keyManager = DemoKeyManager()
        let manager = AlbumManager(keyManager: keyManager)
        let album = makeCloudKitAlbum()

        manager.delete(album: album)

        let deadline = Date().addingTimeInterval(5)
        while store.fetchMetadataCalls.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(store.fetchMetadataCalls.isEmpty,
                       "deleteCloudKitAlbumRecord must attempt to enumerate chunk members")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(store.deletedAlbumCalls.isEmpty,
                      "A failed chunk enumeration must NOT proceed to deleteAlbum — chunks would be permanently orphaned")

        guard let hash = album.albumID else {
            XCTFail("a CloudKit album must have an albumID")
            return
        }
        let queue = CloudKitAlbumDeleteQueue()
        XCTAssertTrue(queue.pending().contains(hash),
                      "The album must remain queued so the reconciler retries the full delete sequence")

        queue.remove(hash)
    }
}
