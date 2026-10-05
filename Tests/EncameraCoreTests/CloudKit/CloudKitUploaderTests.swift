//
//  CloudKitUploaderTests.swift
//  EncameraCoreTests
//
//  How the uploader resolves a failed save: what it completes, what it gives up
//  on, what it drops and what it retries. Every failure is shaped the way the
//  store reports it — per-record errors wrapped in `.partial`.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class CloudKitUploaderTests: XCTestCase {

    static let albumID = "a1"

    private var tempRoot: URL!
    private var deleteQueueSuites: [String] = []

    /// The store behind the album's coordinator. Program its fault hooks before
    /// calling `drain()`.
    private var store: MockCloudKitMediaStore!
    private var queue: CloudKitUploadQueue!
    private var deleteQueue: CloudKitMediaDeleteQueue!
    private var coordinator: CloudKitSyncCoordinator!
    private var reporter: CloudKitSyncStatusReporter!
    private var uploader: CloudKitUploader!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-uploader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = MockCloudKitMediaStore()
        queue = CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("uploads", isDirectory: true))
        deleteQueue = makeDeleteQueue()
        coordinator = makeCoordinator(store: store, uploadQueue: queue, deleteQueue: deleteQueue)
        let registry = CloudKitCoordinatorRegistry()
        _ = await registry.coordinator(forAlbumID: Self.albumID) { coordinator }
        reporter = await MainActor.run { CloudKitSyncStatusReporter() }
        uploader = CloudKitUploader(queue: queue, registry: registry, statusReporter: reporter)
    }

    override func tearDown() async throws {
        await uploader?.shutdown()
        try? FileManager.default.removeItem(at: tempRoot)
        for suite in deleteQueueSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        deleteQueueSuites = []
        CloudKitKnownDeletedRecords.shared.removeAll()
        try await super.tearDown()
    }

    // MARK: - Harness

    /// Each test gets its own delete-queue suite: the queue is durable and
    /// process-wide, so an entry left by one test would leak into the next.
    func makeDeleteQueue() -> CloudKitMediaDeleteQueue {
        let suite = "ck-uploader-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(suite)
        return CloudKitMediaDeleteQueue(suiteName: suite)
    }

    func makeCoordinator(store: MockCloudKitMediaStore,
                         uploadQueue: CloudKitUploadQueue,
                         deleteQueue: CloudKitMediaDeleteQueue) -> CloudKitSyncCoordinator {
        let index = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32),
                                    indexURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encindex"))
        let cache = CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-\(UUID().uuidString)"),
                                      maxBytes: 500 * 1024 * 1024)
        return CloudKitSyncCoordinator(albumID: Self.albumID, store: store, cache: cache, indexStore: index,
                                       bus: FileOperationBus(), uploadQueue: uploadQueue,
                                       deleteQueue: deleteQueue)
    }

    /// Puts a capture in the upload queue, as `CloudKitFileAccess.saveSingle` does.
    @discardableResult
    func enqueueCapture(mediaID: String = UUID().uuidString,
                        contents: String = "ciphertext") async throws -> CloudKitMediaUpload {
        let source = tempRoot.appendingPathComponent("cap-\(UUID().uuidString).photo")
        try Data(contents.utf8).write(to: source)
        let upload = CloudKitMediaUpload(albumID: Self.albumID,
                                         mediaID: mediaID,
                                         mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 100),
                                         sizeBytes: Int64(contents.utf8.count),
                                         encryptedFileURL: source,
                                         encryptedThumbURL: nil)
        return try await queue.enqueue(upload)
    }

    /// The server's copy of `upload`, as `fetchRecordMetadata` would return it.
    func serverRecord(for upload: CloudKitMediaUpload,
                      albumID: String? = nil,
                      sizeBytes: Int64? = nil) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: upload.recordName,
                              albumID: albumID ?? upload.albumID,
                              mediaID: upload.mediaID,
                              mediaType: upload.mediaType,
                              createdAt: upload.createdAt,
                              sizeBytes: sizeBytes ?? upload.sizeBytes,
                              creationDeviceID: "device",
                              schemaVersion: upload.schemaVersion,
                              keyFingerprint: upload.keyFingerprint,
                              recordChangeTag: "tag-server")
    }

    /// A per-record CloudKit error wrapped the way a single-record save reports it.
    func partial(_ code: CKError.Code, for recordName: String) -> CloudKitMediaStoreError {
        .partial(failed: [recordName: CKErrorFactory.error(code)])
    }

    func drain() async {
        await uploader.drainNow()
    }

    func pending(_ recordName: String) async -> CloudKitPendingUpload? {
        await queue.pendingItem(recordName: recordName)
    }

    func stalledCount() async -> Int {
        await MainActor.run { reporter.stalledCount }
    }

    // MARK: - Quota

    /// Quota reaches the uploader wrapped in `.partial`. Unrecognised, it was
    /// retried forever and the status bar said "Up to date" while iCloud was full.
    func testPartialQuotaExceededGivesUp() async throws {
        let upload = try await enqueueCapture()
        store.uploadFailures[upload.recordName] = partial(.quotaExceeded, for: upload.recordName)

        await drain()

        let given = await queue.givenUp().map(\.recordName)
        XCTAssertEqual(given, [upload.recordName], "a per-record quota failure gives the item up")
        let stalled = await stalledCount()
        XCTAssertEqual(stalled, 1, "the pass reports the item as stalled")
        let activity = await MainActor.run { reporter.activity }
        XCTAssertEqual(activity, .stalled(count: 1), "the status bar shows stalled, not up to date")
        XCTAssertTrue(FileManager.default.fileExists(atPath: upload.encryptedFileURL.path),
                      "giving up keeps the only copy of the capture")
    }

    // MARK: - Conflict

    /// A kill between a committed save and `queue.complete` leaves the item
    /// queued; its next save conflicts with its own record. Retrying conflicts
    /// forever, so the item must complete against the record that is there.
    func testConflictAfterCommittedSaveCompletes() async throws {
        let upload = try await enqueueCapture()
        store.metadataToReturn = [serverRecord(for: upload)]
        store.uploadFailures[upload.recordName] = partial(.serverRecordChanged, for: upload.recordName)

        await drain()

        let item = await pending(upload.recordName)
        XCTAssertNil(item, "the item completes against its own committed record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.encryptedFileURL.path),
                       "completing drops the durable copy")
        XCTAssertEqual(store.fetchRecordMetadataCalls, [upload.recordName],
                       "the record is checked by id before the item is completed")
        let given = await queue.givenUp()
        XCTAssertTrue(given.isEmpty)
        let stalled = await stalledCount()
        XCTAssertEqual(stalled, 0)
    }

    /// A record under the same name whose size or album differs is not this
    /// item's. Completing on it would delete the only copy of a photo that never
    /// reached CloudKit.
    func testConflictWithMismatchedRecordDoesNotComplete() async throws {
        let sizeMismatch = try await enqueueCapture(contents: "ciphertext")
        let albumMismatch = try await enqueueCapture(contents: "other bytes")
        store.metadataToReturn = [
            serverRecord(for: sizeMismatch, sizeBytes: sizeMismatch.sizeBytes + 1),
            serverRecord(for: albumMismatch, albumID: "another-album")
        ]
        for upload in [sizeMismatch, albumMismatch] {
            store.uploadFailures[upload.recordName] = partial(.serverRecordChanged, for: upload.recordName)
        }

        await drain()

        for upload in [sizeMismatch, albumMismatch] {
            let item = await pending(upload.recordName)
            XCTAssertNotNil(item, "a foreign record must not complete the item")
            XCTAssertEqual(item?.hasGivenUp, true, "the item stops retrying a conflict it cannot win")
            XCTAssertTrue(item?.lastError?.contains("already in iCloud") ?? false,
                          "the give-up carries a reason: \(item?.lastError ?? "nil")")
            XCTAssertTrue(FileManager.default.fileExists(atPath: upload.encryptedFileURL.path),
                          "the durable copy is kept")
        }
        let stalled = await stalledCount()
        XCTAssertEqual(stalled, 2, "both show as stalled")
    }

    // MARK: - Cancelled

    /// The item is deleted while its save is in flight; the save lands, the
    /// coordinator reclaims the fresh record and throws `.cancelled`. Retrying
    /// would upload the deleted photo again.
    func testCancelledUploadIsDroppedNotRetried() async throws {
        let upload = try await enqueueCapture()
        let coordinator = self.coordinator!
        store.onUploadStarted = {
            try? await coordinator.remove(recordName: upload.recordName, albumID: Self.albumID)
        }

        await drain()
        store.onUploadStarted = nil

        let item = await pending(upload.recordName)
        XCTAssertNil(item, "the deleted item leaves the queue")
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.encryptedFileURL.path),
                       "its durable copy goes with it")
        XCTAssertFalse(store.liveRecordNames.contains(upload.recordName),
                       "the record that landed after the delete was reclaimed")

        await uploader.retryFailed()
        await drain()
        XCTAssertEqual(store.uploadCalls, [upload.mediaID], "the dropped item is never uploaded again")
    }

    /// `.cancelled` also stands for a CloudKit operation that was cancelled —
    /// the drain stopping, say. The photo is still wanted, so it must be retried.
    func testCancelledOperationWithoutDeleteIsRetried() async throws {
        let upload = try await enqueueCapture()
        store.uploadErrorOnce = partial(.operationCancelled, for: upload.recordName)

        await drain()

        let item = await pending(upload.recordName)
        XCTAssertNotNil(item, "a cancelled operation keeps the item")
        XCTAssertEqual(item?.hasGivenUp, false)
        XCTAssertEqual(item?.attempts, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: upload.encryptedFileURL.path))
    }
}
