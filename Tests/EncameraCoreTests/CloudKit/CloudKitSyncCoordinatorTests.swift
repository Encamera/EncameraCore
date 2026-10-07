//
//  CloudKitSyncCoordinatorTests.swift
//  EncameraCoreTests
//
//  Chunk 03 — coordinator + evictable cache, exercised against the mock store.
//

import XCTest
import Combine
@testable import EncameraCore

final class CloudKitSyncCoordinatorTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        for suite in deleteQueueSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        deleteQueueSuites = []
        CloudKitKnownDeletedRecords.shared.removeAll()
    }

    // MARK: - Builders

    private func makeIndexStore() -> MediaIndexStore {
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString).encindex")
        return MediaIndexStore(keyBytes: Array(repeating: 7, count: 32), indexURL: url)
    }

    private func makeCache() -> CloudKitBlobCache {
        CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-\(UUID().uuidString)"),
                          maxBytes: 500 * 1024 * 1024)
    }

    private func makeCoordinator(store: MockCloudKitMediaStore,
                                 bus: FileOperationBus = FileOperationBus(),
                                 deleteQueue: CloudKitMediaDeleteQueue? = nil,
                                 sizeSidecar: AlbumSizeSidecar? = nil,
                                 chunkStore: ChunkedBlobStoring? = nil)
        -> (CloudKitSyncCoordinator, MediaIndexStore, CloudKitBlobCache) {
        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            sizeSidecar: sizeSidecar,
                                            bus: bus, deleteQueue: deleteQueue ?? makeDeleteQueue(),
                                            chunkStore: chunkStore)
        return (coord, index, cache)
    }

    private func makeSizeSidecar() -> AlbumSizeSidecar {
        AlbumSizeSidecar(fileURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encsizes"))
    }

    /// The delete queue is durable and process-wide, so tests must not share one:
    /// an entry left behind by one test would suppress another's upserts and issue
    /// phantom deletes. Each gets its own defaults suite, removed in teardown, and
    /// its own known-deleted set — otherwise a name one test marked would make
    /// another's reads of the same name fail closed.
    private var deleteQueueSuites: [String] = []

    private func makeDeleteQueue() -> CloudKitMediaDeleteQueue {
        let suite = "ck-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(suite)
        return CloudKitMediaDeleteQueue(suiteName: suite)
    }

    private func meta(_ name: String,
                      type: MediaType = .photo,
                      tag: String? = "tag-1") -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: name,
                              albumID: "a1",
                              mediaID: name,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: 10,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              recordChangeTag: tag)
    }

    /// A single component of a media item (Live Photos share a mediaID across two records).
    private func metaComponent(recordName: String, mediaID: String, type: MediaType) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName,
                              albumID: "a1",
                              mediaID: mediaID,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: 10,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              recordChangeTag: "tag-\(recordName)")
    }

    private func ids(_ store: MediaIndexStore) async -> [String] {
        (await store.load()?.entries ?? []).map { $0.id }.sorted()
    }

    /// Collects every fraction a caller's progress closure was handed.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []

        var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }

        var record: @Sendable (Double) -> Void {
            { [self] fraction in
                lock.lock(); _values.append(fraction); lock.unlock()
            }
        }
    }

    /// Records whether a second paired update completed inside the first one.
    private final class MidUpdateWitness: @unchecked Sendable {
        private let lock = NSLock()
        private var _landed = false

        var landed: Bool { lock.withLock { _landed } }

        func record() { lock.withLock { _landed = true } }
    }

    /// Records chunk deletes and nothing else, so a test can prove a drain did or
    /// did not reach the blob zone.
    private actor ChunkDeleteRecorder: ChunkedBlobStoring {
        private(set) var deletes: [(mediaRecordName: String, chunkCount: Int)] = []

        func uploadChunks(enc3FileURL: URL, mediaRecordName: String,
                          existingChunks: ExistingChunkPolicy,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
            throw ChunkedBlobError.chunkNotFound(mediaRecordName)
        }

        func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
            throw ChunkedBlobError.chunkNotFound(mediaRecordName)
        }

        func delete(mediaRecordName: String, chunkCount: Int) async throws {
            deletes.append((mediaRecordName, chunkCount))
        }

        var deletedNames: [String] { deletes.map(\.mediaRecordName) }
    }

    private func photoUpload(_ mediaID: String) -> CloudKitMediaUpload {
        CloudKitMediaUpload(albumID: "a1", mediaID: mediaID, mediaType: .photo,
                            createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                            encryptedFileURL: URL(fileURLWithPath: "/tmp/\(mediaID).blob"),
                            encryptedThumbURL: nil)
    }

    /// Polls until `condition` holds, failing the test if it does not within a second.
    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        try await withTimeout(seconds: 1) {
            while !condition() { try await Task.sleep(nanoseconds: 1_000_000) }
        }
    }

    private struct TestTimeout: Error {}

    /// Fails fast instead of hanging the suite: every download assertion here is
    /// about a caller being released, so a wedged `await` is the failure.
    private func withTimeout<T: Sendable>(seconds: Double,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Sync reconciliation

    func testSyncUpsertsChangedRecordsIntoIndex() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        try await coord.sync(albumID: "a1")

        let result = await ids(index)
        XCTAssertEqual(result, ["m1", "m2"])
    }

    func testSyncRemovesDeletedRecordsAndEvicts() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })

        let afterUpsert = await ids(index)
        XCTAssertEqual(afterUpsert, ["m1"], "The record has to be indexed before its removal means anything")
        let cachedBefore = await coord.isBlobCached(recordName: "m1")
        XCTAssertTrue(cachedBefore, "The blob has to be cached before its eviction means anything")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let result = await ids(index)
        XCTAssertTrue(result.isEmpty, "A deleted record leaves the index")
        let cachedAfter = await coord.isBlobCached(recordName: "m1")
        XCTAssertFalse(cachedAfter, "A deleted record's ciphertext is evicted from the blob cache")
    }

    func testSyncThrowsAndLeavesIndexUnchangedOnError() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.fetchChangesError = CKErrorFactory.error(.networkUnavailable)
        do {
            try await coord.sync(albumID: "a1")
            XCTFail("Expected throw")
        } catch {
        }
        let result = await ids(index)
        XCTAssertEqual(result, ["m1"], "A failed sync must not mutate the index")
    }

    // MARK: - Blob residency

    func testEnsureBlobLocalCachesOnMissAndHitsCacheOnSecondCall() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        let url1 = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        let url2 = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "Second call must hit the cache")
        XCTAssertEqual(url1, url2)
    }

    func testConcurrentEnsureBlobLocalDedupsToSingleFetch() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobDelayNanos = 50_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        async let r1 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        async let r2 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        async let r3 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        async let r4 = coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        let urls = try await [r1, r2, r3, r4]

        XCTAssertEqual(store.fetchBlobCount, 1, "Concurrent callers share one fetch")
        XCTAssertEqual(Set(urls).count, 1)
    }

    func testEvictRemovesLocalKeepsCloud() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        try await coord.evict(recordName: "m1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })

        XCTAssertEqual(store.fetchBlobCount, 2, "Eviction forces a re-fetch from cloud")
    }

    func testChangeTagInvalidationRefetches() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t2")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 2, "A new change tag invalidates the stale cached file")
    }

    func testEvictAllOlderThanForcesRefetch() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        try await coord.evictAll(olderThan: Date().addingTimeInterval(60))
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })

        XCTAssertEqual(store.fetchBlobCount, 2)
    }

    // MARK: - Download cancel / retry

    /// A cancelled download must actually stop. Awaiting an unstructured
    /// `Task.value` ignores the awaiting task's cancellation, so tapping Cancel
    /// left the caller parked for the full remaining download AND left the
    /// CloudKit fetch running.
    func testCancellingTheOnlyWaiterStopsTheFetchAndThrowsCancellation() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let download = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        download.cancel()

        do {
            _ = try await withTimeout(seconds: 3) { try await download.value }
            XCTFail("A cancelled download must not resolve — the caller has to be released immediately")
        } catch is CancellationError {
        }
        for _ in 0..<50 where store.fetchBlobCancelledCount == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.fetchBlobCancelledCount, 1,
                       "The CloudKit fetch itself must be cancelled once its last waiter goes away")
    }

    /// A cancelled download must leave nothing behind. This is the timing-free
    /// statement of "the transfer really stopped" — and the property the on-device
    /// probe asserts, because a rig's link is far too fast to judge by the clock.
    func testCancelledDownloadLeavesNothingInTheBlobCache() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let download = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        download.cancel()
        _ = try? await withTimeout(seconds: 3) { try await download.value }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        _ = try await coord.ensureBlobLocal(recordName: "m2", albumID: "a1", progress: { _ in })
        let control = await coord.isBlobCached(recordName: "m2")
        XCTAssertTrue(control, "A download allowed to finish caches its blob")

        let cached = await coord.isBlobCached(recordName: "m1")
        XCTAssertFalse(cached, "A cancelled download must not go on to finish and cache its blob")
    }

    /// The reported bug: start a download, cancel it, start it again — the second
    /// attempt froze at 0% (or at whatever the first attempt last showed) because
    /// it joined the abandoned fetch, whose progress closure belonged to the
    /// cancelled caller.
    func testDownloadRestartedAfterACancelReportsProgressAndCompletes() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the first download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let abandoned = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        abandoned.cancel()

        let retry = ProgressRecorder()
        let url = try await withTimeout(seconds: 15) {
            try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: retry.record)
        }

        XCTAssertFalse(retry.values.isEmpty,
                       "The restarted download must report progress; a silent one is the frozen bar the user sees")
        XCTAssertEqual(retry.values.last, 1.0, "The restarted download must finish at 100%")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The retry must produce a readable blob")
    }

    /// Two callers for the same record still share one fetch — but the joiner has
    /// to be fed progress too, and to start from where the download actually is.
    func testJoiningCallerReceivesProgressFromTheSharedFetch() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let first = ProgressRecorder()
        let joiner = ProgressRecorder()
        let leader = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: first.record) }
        await fulfillment(of: [inFlight], timeout: 5)

        let joinedURL = try await withTimeout(seconds: 15) {
            try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: joiner.record)
        }
        let leaderURL = try await leader.value

        XCTAssertEqual(store.fetchBlobCount, 1, "Concurrent callers must still share one fetch")
        XCTAssertEqual(joinedURL, leaderURL)
        XCTAssertFalse(joiner.values.isEmpty, "A joiner must see the shared download's progress")
        XCTAssertEqual(joiner.values.last, 1.0)
        XCTAssertGreaterThanOrEqual(joiner.values.first ?? 0, 0.2,
                                    "A joiner must start from the fraction already reached, not from zero")
    }

    /// Cancelling one caller must not strand the others: the fetch is cancelled
    /// only when the LAST interested caller goes away.
    func testCancellingOneWaiterLeavesTheSharedDownloadRunningForTheOther() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchBlobProgressSteps = [0.2, 0.4, 0.6, 0.8]
        store.fetchBlobStepNanos = 150_000_000
        let (coord, _, _) = makeCoordinator(store: store)

        let inFlight = expectation(description: "the download reported its first fraction")
        inFlight.assertForOverFulfill = false
        store.onFirstProgress = { inFlight.fulfill() }

        let stayer = ProgressRecorder()
        let leaving = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in }) }
        await fulfillment(of: [inFlight], timeout: 5)
        let staying = Task { try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: stayer.record) }
        try await Task.sleep(nanoseconds: 100_000_000)
        leaving.cancel()

        let url = try await withTimeout(seconds: 15) { try await staying.value }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.fetchBlobCancelledCount, 0,
                       "A fetch with a remaining waiter must not be cancelled")
        XCTAssertEqual(store.fetchBlobCount, 1, "The remaining waiter keeps the original fetch, it does not restart it")
    }

    // MARK: - Cross-device delete

    func testRemoveDeletesTheRecordImmediately() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        try await coord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "The record is removed now, not soft-deleted and swept later")
        let afterRemove = await ids(index)
        XCTAssertTrue(afterRemove.isEmpty)

        do {
            _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
            XCTFail("Expected notFound for a deleted record")
        } catch let error as CloudKitMediaStoreError {
            guard case .notFound = error else { return XCTFail("Wrong error: \(error)") }
        }

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "A confirmed delete must not be retried")
    }

    /// A delete the server refuses is not lost: it is persisted and retried by the
    /// next sync, and until it lands the record must not be pulled back into the
    /// index from its still-live remote copy.
    func testAFailedDeleteIsRetriedAndDoesNotResurrectTheRecord() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.deleteError = CloudKitMediaStoreError.retry(after: 1)
        try await coord.remove(recordName: "m1", albumID: "a1")

        let afterFailedDelete = await ids(index)
        XCTAssertTrue(afterFailedDelete.isEmpty,
                      "The item leaves this device even when the server call fails")

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, ["m1", "m1"], "The queued delete is retried on the next sync")
        let afterRetry = await ids(index)
        XCTAssertTrue(afterRetry.isEmpty, "A record pending deletion must never be re-materialized")

        store.deleteError = nil
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1", "m1", "m1"])

        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1", "m1", "m1"], "A drained delete is not retried again")
    }

    func testRemoveReportsQueuedWhenRemoteDeleteFails() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.deleteError = CloudKitMediaStoreError.retry(after: 1)

        let outcome = try await coord.remove(recordName: "m1", albumID: "a1")

        XCTAssertEqual(outcome, .queued, "a delete the server refused is only queued")
    }

    func testRemoveReportsConfirmedOnNotFound() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.deleteError = CloudKitMediaStoreError.notFound

        let outcome = try await coord.remove(recordName: "m1", albumID: "a1")

        XCTAssertEqual(outcome, .confirmed, "a record already gone counts as deleted")
    }

    /// The retry survives the process: the intent lives in the queue, not in the
    /// coordinator that formed it.
    func testAQueuedDeleteIsRetriedByAFreshCoordinator() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.deleteErrorOnce = CloudKitMediaStoreError.retry(after: 1)
        try await coord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(queue.pending(), ["m1"], "An unconfirmed delete is persisted")

        let (fresh, _, _) = makeCoordinator(store: store, deleteQueue: queue)
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await fresh.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, ["m1", "m1"])
        XCTAssertTrue(queue.pending().isEmpty, "A confirmed delete drains")
    }

    /// An item still in the upload queue may already be in CloudKit: the save
    /// committed, then the app was killed before the queue cleared the item.
    /// Deleting it must still reach the record, through the delete queue.
    func testRemovingPendingItemQueuesRemoteDelete() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue)

        let source = tempRoot.appendingPathComponent("landed.photo")
        try Data("ciphertext".utf8).write(to: source)
        _ = try await store.upload(CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                                       createdAt: Date(timeIntervalSince1970: 100),
                                                       sizeBytes: 10, encryptedFileURL: source,
                                                       encryptedThumbURL: nil, recordName: "m1"),
                                   progress: { _ in })
        XCTAssertEqual(store.liveRecordNames, ["m1"], "the save landed before the kill")

        store.deleteErrorOnce = CloudKitMediaStoreError.retry(after: 1)
        try await coord.remove(recordName: "m1", albumID: "a1", wasPending: true)
        XCTAssertEqual(queue.pending(), ["m1"], "a pending item's delete is queued like any other")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, ["m1", "m1"], "the drain retries the delete")
        XCTAssertFalse(store.liveRecordNames.contains("m1"), "the landed record is gone from CloudKit")
        XCTAssertTrue(queue.pending().isEmpty, "the confirmed delete drains")
    }

    /// The common case: the pending item never reached CloudKit. Its delete is
    /// issued anyway, finds nothing, and counts as done.
    func testRemovingPendingItemThatNeverLandedConfirmsTheDelete() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue)
        store.deleteError = CloudKitMediaStoreError.notFound

        try await coord.remove(recordName: "m1", albumID: "a1", wasPending: true)

        XCTAssertEqual(store.deleteCalls, ["m1"])
        XCTAssertTrue(queue.pending().isEmpty, "an absent record counts as deleted")
    }

    /// When resolveChunkCount returns unknownChunkCount (transient fetch failure),
    /// remove() must NOT delete the commit record — otherwise drainPendingDeletes
    /// cannot resolve geometry (the record is gone → nil → 0) and the chunk records
    /// are orphaned permanently.
    func testRemoveDefersCommitRecordDeleteWhenChunkCountIsUnknown() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let index = makeIndexStore()
        let cache = makeCache()

        let videoMeta = CloudKitMediaMetadata(recordName: "vid#1",
                                              albumID: "a1",
                                              mediaID: "vid",
                                              mediaType: .video,
                                              createdAt: Date(timeIntervalSince1970: 100),
                                              sizeBytes: 50_000_000,
                                              creationDeviceID: "device",
                                              schemaVersion: 1,
                                              keyFingerprint: "",
                                              recordChangeTag: "tag-1",
                                              chunkCount: 12,
                                              plaintextLength: 48_000_000)
        store.changeSet = CloudKitChangeSet(changed: [videoMeta], deleted: [], token: nil, moreComing: false)
        let first = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache,
                                            indexStore: index, bus: FileOperationBus(), deleteQueue: queue)
        try await first.sync(albumID: "a1")

        store.fetchRecordMetadataError = CloudKitMediaStoreError.retry(after: 1)
        let relaunched = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache,
                                                  indexStore: index, bus: FileOperationBus(), deleteQueue: queue)

        try await relaunched.remove(recordName: "vid#1", albumID: "a1")

        let deleteCalls = store.deleteCalls
        XCTAssertEqual(deleteCalls, [],
                       "remove() must not delete the commit record when chunk geometry is unknown — "
                       + "drainPendingDeletes needs the record alive to resolve chunk count; got \(deleteCalls)")
        let pending = queue.pending()
        XCTAssertTrue(pending.contains("vid#1"),
                      "The delete intent must still be queued; pending=\(pending)")
    }

    func testCachedBlobSurvivesRelaunchBeforeTagMapRepopulates() async throws {
        let store = MockCloudKitMediaStore()
        let index = makeIndexStore()
        let cache = makeCache()
        let deleteQueue = makeDeleteQueue()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: FileOperationBus(), deleteQueue: deleteQueue)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        let relaunched = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                                 bus: FileOperationBus(), deleteQueue: deleteQueue)
        _ = try await relaunched.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "A persisted cache entry with no newer known tag must be a hit after relaunch")
    }

    // MARK: - Push / notifications

    func testStartObservingSkipsSubscriptionWhenNoAccount() async {
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        let (coord, _, _) = makeCoordinator(store: store)

        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionAttempts, 0,
                       "With no account the coordinator must not even reach the store")
        XCTAssertEqual(store.registerSubscriptionCount, 0)

        store.accountAvailableValue = true
        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionAttempts, 1)
        XCTAssertEqual(store.registerSubscriptionCount, 1)
    }

    func testSyncRetriesFailedSubscriptionRegistration() async throws {
        let store = MockCloudKitMediaStore()
        store.registerSubscriptionError = CloudKitMediaStoreError.retry(after: 0)
        let (coord, _, _) = makeCoordinator(store: store)

        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionAttempts, 1, "registration was attempted")
        XCTAssertEqual(store.registerSubscriptionCount, 0, "registration failed and was not recorded")

        store.registerSubscriptionError = nil
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.registerSubscriptionCount, 1,
                       "a sync self-heals a previously failed push registration")
    }

    func testEverySyncReattemptsRegistrationSoStoreInvalidationSelfHeals() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        try await coord.sync(albumID: "a1")
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.registerSubscriptionCount, 2,
                       "each sync must delegate the register-or-no-op decision to the store")
    }

    func testRemoteNotificationTriggersSync() async {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        await coord.handleRemoteNotification([:])

        XCTAssertEqual(store.fetchChangesCount, 1)
        let result = await ids(index)
        XCTAssertEqual(result, ["m1"])
    }

    func testEmitsFileOperationBusEvents() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            switch operation {
            case .create(let media): created.append(media.id)
            case .delete(let medias): deleted.append(contentsOf: medias.map { $0.id })
            case .move, .albumCoverChanged: break
            }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m2"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(created.values, ["m1", "m2"])
        XCTAssertEqual(deleted.values, ["m2"])
    }

    // MARK: - Bugbot regressions

    /// A stale hard-delete (record already gone elsewhere) must not abort the whole sync.
    func testSyncToleratesARecordAlreadyGoneFromTheZone() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.deleteError = CloudKitMediaStoreError.notFound
        try await coord.remove(recordName: "m1", albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "A notFound delete should be dropped, not retried")
    }

    /// A Live Photo arrives as two records sharing one mediaID; the index entry must
    /// carry both components or `materialize` drops the item from the gallery.
    func testSyncMergesLivePhotoComponentsIntoOneEntry() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        let entries = await index.load()?.entries ?? []
        let entry = entries.first { $0.id == "live" }
        XCTAssertNotNil(entry, "The Live Photo must produce one index entry")
        XCTAssertEqual(entry?.hasPhotoComponent, true)
        XCTAssertEqual(entry?.hasVideoComponent, true)
    }

    /// Deleting ONE component of a Live Photo must keep the entry while the other
    /// component survives — only clear that component's flag.
    func testDeletingOneLivePhotoComponentKeepsTheOther() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let entry = (await index.load()?.entries ?? []).first { $0.id == "live" }
        XCTAssertNotNil(entry, "The Live Photo must remain while one component survives")
        XCTAssertEqual(entry?.hasPhotoComponent, false)
        XCTAssertEqual(entry?.hasVideoComponent, true)
    }

    /// Removing the last surviving component drops the entry entirely.
    func testDeletingBothLivePhotoComponentsRemovesEntry() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let seeded = (await index.load()?.entries ?? []).first { $0.id == "live" }
        XCTAssertNotNil(seeded, "The entry has to exist before its removal means anything")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0", "live#1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let remaining = await index.load()?.entries ?? []
        XCTAssertTrue(remaining.isEmpty, "Both components gone => entry removed")
    }

    /// An expired change token must trigger a reset + full resync, not a hard failure.
    func testSyncRecoversFromExpiredChangeToken() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.fetchChangesErrorOnce = CloudKitMediaStoreError.changeTokenExpired
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.resetChangeTokenCount, 1, "Expired token should be reset")
        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "Resync after reset should populate the index")
    }

    /// Synced records must carry `dateEncrypted` so default gallery sorting (by
    /// encrypted date) orders them by capture time, not dumps them at the end.
    func testSyncedItemsCarryEncryptedDateForSorting() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        func dated(_ name: String, _ date: Date) -> CloudKitMediaMetadata {
            CloudKitMediaMetadata(recordName: name, albumID: "a1", mediaID: name, mediaType: .photo,
                                  createdAt: date, sizeBytes: 1, creationDeviceID: "d",
                                  schemaVersion: 1, recordChangeTag: "t-\(name)")
        }
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        store.changeSet = CloudKitChangeSet(changed: [
            dated("z-newest", later),
            dated("a-oldest", earlier)
        ], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        let entries = await index.load()?.entries ?? []
        XCTAssertEqual(entries.first { $0.id == "z-newest" }?.dateEncrypted, later,
                       "The entry's encrypted date is the record's capture date, not the wall clock")
        XCTAssertEqual(entries.first { $0.id == "a-oldest" }?.dateEncrypted, earlier)
        let sorted = MediaIndex(entries: entries).sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
        XCTAssertEqual(sorted.map { $0.id }, ["z-newest", "a-oldest"], "Newest capture first")
    }

    /// A record already present in the index must not re-emit a create on resync,
    /// or the gallery does redundant reconcile work for the whole album.
    func testSyncEmitsCreateOnlyForNewEntries() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .create(let media) = operation { created.append(media.id) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(created.values, ["m1"], "Create should fire once, only for the genuinely new entry")
    }

    /// A delete for a record this album never held (another album in the shared zone)
    /// must not emit a delete event or mutate this coordinator's state.
    func testSyncIgnoresDeletesForOtherAlbums() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .delete(let medias) = operation { deleted.append(contentsOf: medias.map { $0.id }) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["other#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertTrue(deleted.values.isEmpty, "Deletes for other albums must be ignored")
        let remaining = await ids(index)
        XCTAssertEqual(remaining, ["m1"], "Our album's index must be untouched")
    }

    // MARK: - Local artifact cleanup on delete

    /// The encrypted preview is a real file on disk, so a delete that removes the
    /// index entry and the cached blob but leaves the thumbnail behind is a silent
    /// leak that grows with every cross-device delete.
    func testCrossDeviceDeleteRemovesTheLocalPreview() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let previewURL = CloudKitStorageModel.previewURL(forMediaID: "m1")
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path),
                       "A hard delete must take the encrypted preview with it")
    }

    /// A Live Photo's two components share ONE preview file, so clearing the first
    /// component must not delete the thumbnail the surviving component still needs.
    func testDeletingOneLivePhotoComponentKeepsTheSharedPreview() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let previewURL = CloudKitStorageModel.previewURL(forMediaID: "live")
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let entry = (await index.load()?.entries ?? []).first { $0.id == "live" }
        XCTAssertEqual(entry?.hasPhotoComponent, false, "The delete has to land before the preview claim means anything")
        XCTAssertEqual(entry?.hasVideoComponent, true, "The video component survives, so the preview is still in use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
                      "The video component still needs the shared preview")
    }

    /// The cached ciphertext must be dropped even when the index entry is already
    /// gone — otherwise the blob is stranded on disk with nothing left to evict it.
    func testDeleteEvictsCachedBlobEvenWhenNotInThisAlbumsIndex() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, cache) = makeCoordinator(store: store)

        let source = tempRoot.appendingPathComponent("stranded.blob")
        try Data("ciphertext".utf8).write(to: source)
        _ = try await cache.store(recordName: "gone#0", changeTag: "t1", albumID: "a1", from: source)
        let cachedBefore = await cache.cachedURL(recordName: "gone#0", changeTag: "t1")
        XCTAssertNotNil(cachedBefore)

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["gone#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let cached = await cache.cachedURL(recordName: "gone#0", changeTag: "t1")
        XCTAssertNil(cached, "A record deleted from the zone must not keep a cached blob")
    }

    /// The record name encodes the component type, so a hard delete can emit a
    /// well-typed bus event instead of `.unknown`.
    func testHardDeleteEmitsTypedBusEvent() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let types = TypeRecorder()
        let cancellable = bus.operations.sink { operation in
            if case .delete(let medias) = operation { types.append(contentsOf: medias.map { $0.mediaType }) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: makeCache(), indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "v1#1", mediaID: "v1", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["v1#1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(types.values, [.video], "The component type is recoverable from the record name")
    }

    // MARK: - Reap on a full resync

    /// A record deleted while this device's token was expired never appears in the
    /// change feed, so only an acknowledged from-scratch fetch can notice it is gone.
    func testFullResyncReapsEntriesAbsentFromACompleteSnapshot() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")],
                                            deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        let afterFirst = await ids(index)
        XCTAssertEqual(afterFirst, ["m1", "m2"])

        store.changeSet = CloudKitChangeSet(changed: [meta("m2")], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: true)
        try await coord.sync(albumID: "a1")

        let afterSnapshot = await ids(index)
        XCTAssertEqual(afterSnapshot, ["m2"], "A record absent from a complete snapshot is gone")
    }

    /// Absence only means deletion when the server acknowledged the fetch. An
    /// unacknowledged answer may be partial, and reaping on it deletes live media.
    func testUnacknowledgedFullFetchDoesNotReap() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")],
                                            deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [meta("m2")], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: false)
        try await coord.sync(albumID: "a1")

        let afterUnacked = await ids(index)
        XCTAssertEqual(afterUnacked, ["m1", "m2"], "Never reap on an answer we cannot vouch for")
    }

    /// A capture that has not uploaded yet is legitimately in the index and
    /// legitimately absent from the server. Reaping it would delete the user's
    /// photo before its bytes ever left the device.
    func testReapExemptsItemsStillWaitingToUpload() async throws {
        let store = MockCloudKitMediaStore()
        let queue = CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("q-\(UUID().uuidString)"))
        let index = makeIndexStore()
        let coord = CloudKitSyncCoordinator(albumID: "a1",
                                            store: store,
                                            cache: makeCache(),
                                            indexStore: index,
                                            bus: FileOperationBus(),
                                            uploadQueue: queue,
                                            deleteQueue: makeDeleteQueue())

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let pendingFile = tempRoot.appendingPathComponent("pending.blob")
        try Data("ciphertext".utf8).write(to: pendingFile)
        _ = try await queue.enqueue(CloudKitMediaUpload(albumID: "a1",
                                                        mediaID: "queued",
                                                        mediaType: .photo,
                                                        createdAt: Date(),
                                                        sizeBytes: 10,
                                                        encryptedFileURL: pendingFile,
                                                        encryptedThumbURL: nil,
                                                        recordName: "queued#0"))
        try await index.upsert([MediaIndexEntry(id: "queued",
                                                hasPhotoComponent: true,
                                                hasVideoComponent: false,
                                                dateEncrypted: Date(),
                                                dateTaken: Date(),
                                                subtypeRawValue: 0),
                                MediaIndexEntry(id: "orphan",
                                                hasPhotoComponent: true,
                                                hasVideoComponent: false,
                                                dateEncrypted: Date(),
                                                dateTaken: Date(),
                                                subtypeRawValue: 0)])

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: true)
        try await coord.sync(albumID: "a1")

        let afterReap = await ids(index)
        XCTAssertEqual(afterReap, ["m1", "queued"],
                       "An item still waiting to upload must survive the reap that took the orphan")
    }

    /// The coordinator is an actor, so a capture's upload can run to completion
    /// while a from-scratch fetch is suspended. The fetch's snapshot predates the
    /// save and the queue no longer lists the capture by the time the reap runs, so
    /// only the pending set taken before the fetch keeps it from being reaped.
    func testReapExemptsUploadThatCompletesDuringFetch() async throws {
        let store = MockCloudKitMediaStore()
        let queue = CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("q-\(UUID().uuidString)"))
        let index = makeIndexStore()
        let deleteQueue = makeDeleteQueue()
        let coord = CloudKitSyncCoordinator(albumID: "a1",
                                            store: store,
                                            cache: makeCache(),
                                            indexStore: index,
                                            bus: FileOperationBus(),
                                            uploadQueue: queue,
                                            deleteQueue: deleteQueue)

        let recordName = MediaRecordName.componentRecordName(mediaID: "capture", type: .photo)
        let capturedFile = tempRoot.appendingPathComponent("capture.blob")
        try Data("ciphertext".utf8).write(to: capturedFile)
        let queued = try await queue.enqueue(CloudKitMediaUpload(albumID: "a1",
                                                                 mediaID: "capture",
                                                                 mediaType: .photo,
                                                                 createdAt: Date(),
                                                                 sizeBytes: 10,
                                                                 encryptedFileURL: capturedFile,
                                                                 encryptedThumbURL: nil,
                                                                 recordName: recordName))
        try await coord.registerLocally(queued)
        let previewURL = CloudKitStorageModel.previewURL(forMediaID: "capture")
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }

        // The server answered the full fetch before the capture's save landed.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: true)
        let gate = AsyncGate()
        store.fetchChangesGate = gate

        let sync = Task { try await coord.sync(albumID: "a1") }
        await gate.waitUntilEntered()

        _ = try await coord.upload(queued, progress: { _ in }, alreadyVisibleLocally: true)
        await queue.complete(recordName: recordName)
        let stillQueued = await queue.all()
        XCTAssertTrue(stillQueued.isEmpty, "Precondition: the upload left the queue while the fetch was suspended")

        await gate.release()
        try await sync.value

        let afterSync = await ids(index)
        XCTAssertEqual(afterSync, ["capture"], "A capture uploaded during the fetch must stay indexed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
                      "A capture uploaded during the fetch must keep its preview")
        XCTAssertFalse(deleteQueue.isKnownDeleted(recordName),
                       "A capture uploaded during the fetch must not be marked deleted")
        let url = try await coord.ensureBlobLocal(recordName: recordName, albumID: "a1", progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: url), Data("ciphertext".utf8), "The capture must stay readable")
    }

    /// A reap only says a full fetch did not return the record. When a later fetch
    /// returns it, it is live, and it must become readable in this session rather
    /// than after a relaunch.
    func testReapedRecordBecomesReadableWhenItReappears() async throws {
        let store = MockCloudKitMediaStore()
        let deleteQueue = makeDeleteQueue()
        let (coord, index, _) = makeCoordinator(store: store, deleteQueue: deleteQueue)
        let recordName = MediaRecordName.componentRecordName(mediaID: "x", type: .photo)
        let record = metaComponent(recordName: recordName, mediaID: "x", type: .photo)

        store.changeSet = CloudKitChangeSet(changed: [record], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [],
                                            token: nil, moreComing: false, snapshotComplete: true)
        try await coord.sync(albumID: "a1")
        let afterReap = await ids(index)
        XCTAssertEqual(afterReap, [], "Precondition: the full fetch reaped the record")
        do {
            _ = try await coord.ensureBlobLocal(recordName: recordName, albumID: "a1", progress: { _ in })
            XCTFail("Precondition: a reaped record reads as deleted")
        } catch CloudKitMediaStoreError.notFound {}

        store.changeSet = CloudKitChangeSet(changed: [record], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let afterReturn = await ids(index)
        XCTAssertEqual(afterReturn, ["x"])
        XCTAssertFalse(deleteQueue.isKnownDeleted(recordName), "The record the server returned is live")
        let url = try await coord.ensureBlobLocal(recordName: recordName, albumID: "a1", progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: url), store.blobContents,
                       "A reaped record that comes back must be readable without a relaunch")
    }

    /// A claim the record has been republished past, or whose delete the server has
    /// confirmed, no longer stands for a delete in progress — so a later mark (a
    /// reap) must not be held in place by it when the server returns the record.
    func testReleasedClaimIsNotActive() {
        let queue = makeDeleteQueue()

        queue.claimDeletion(of: "released", queueRemoteDelete: false)
        queue.forgetDeletion(of: "released")
        queue.markDeletedFromFeed("released")
        queue.clearKnownDeletedIfNotQueued("released")
        XCTAssertFalse(queue.isKnownDeleted("released"),
                       "A released claim must not keep a record the server returned marked")

        let claim = queue.claimDeletion(of: "confirmed", queueRemoteDelete: true)
        XCTAssertTrue(queue.confirmDelete(of: "confirmed", claimedAs: claim))
        queue.clearKnownDeletedIfNotQueued("confirmed")
        XCTAssertFalse(queue.isKnownDeleted("confirmed"),
                       "A confirmed claim must not keep a record the server returned marked")

        queue.claimDeletion(of: "outstanding", queueRemoteDelete: false)
        queue.clearKnownDeletedIfNotQueued("outstanding")
        XCTAssertTrue(queue.isKnownDeleted("outstanding"),
                      "A claim still outstanding keeps the record marked")
    }

    /// Deleting an item still waiting to upload can be confirmed before its
    /// in-flight save lands. A sync that then fetches the landed record must not
    /// unmark it, or the upload keeps the record the user deleted.
    func testAPendingItemDeletedMidUploadIsNotUnmarkedByAFetchedCopy() async throws {
        let store = MockCloudKitMediaStore()
        let deleteQueue = makeDeleteQueue()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: deleteQueue)
        let recordName = MediaRecordName.componentRecordName(mediaID: "m1", type: .photo)
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil, recordName: recordName)

        // The save has landed, so the next fetch returns the record.
        let landed = CloudKitChangeSet(changed: [metaComponent(recordName: recordName, mediaID: "m1", type: .photo)],
                                       deleted: [], token: nil, moreComing: false)
        store.onUploadStarted = { [weak coord, store] in
            guard let coord else { return }
            _ = try? await coord.remove(recordName: recordName, albumID: "a1", wasPending: true)
            store.changeSet = landed
            try? await coord.sync(albumID: "a1")
        }

        do {
            _ = try await coord.upload(upload, progress: { _ in })
            XCTFail("An upload whose item was deleted while it ran must not report success")
        } catch CloudKitMediaStoreError.cancelled {}

        XCTAssertTrue(deleteQueue.isKnownDeleted(recordName),
                      "The fetched copy must not unmark a record deleted while its upload ran")
        XCTAssertEqual(store.deleteCalls.filter { $0 == recordName }.count, 2,
                       "The delete and the record that landed after it must both be removed")
    }

    /// A merge that adds a component (Live Photo video arriving after the photo)
    /// changes the entry, so the gallery must be told to refresh.
    func testLivePhotoMergeEmitsRefresh() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .create(let media) = operation { created.append(media.id) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        store.changeSet = CloudKitChangeSet(changed: [metaComponent(recordName: "live#0", mediaID: "live", type: .photo)], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.changeSet = CloudKitChangeSet(changed: [metaComponent(recordName: "live#1", mediaID: "live", type: .video)], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(created.values, ["live", "live"], "Adding a component must refresh the gallery")
    }

    /// A locally uploaded item must sort consistently with synced items: use the
    /// capture date for `dateEncrypted`, not the wall clock at upload time.
    /// Moving an album out of iCloud calls `remove` for every item, which marks each
    /// record deleted-locally and queues it for a hard purge. Both live in memory on
    /// the album's coordinator, and the registry hands the SAME coordinator back when
    /// the album is moved to iCloud again — so the re-upload lands on bookkeeping
    /// that still says "this record is deleted".
    ///
    /// Left alone, the "a delete that raced this upload wins" guard fires on the very
    /// record the user just asked to upload: it tombstones the fresh record, throws
    /// `.cancelled`, and the queued purge then hard-deletes the photo from iCloud.
    /// The user's album reports a successful move and the media is gone.
    func testUploadAfterTheAlbumMovedOutOfICloudIsANewRecordNotADeleteRace() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        try await coord.remove(recordName: "m1", albumID: "a1")

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)
        _ = try await coord.upload(upload, progress: { _ in })

        XCTAssertEqual(store.deleteCalls, ["m1"],
                       "The only delete belongs to the move out of iCloud — the re-upload must not be deleted")
        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "The re-uploaded record must be back in the local index")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"],
                       "A stale delete must be cancelled by the re-upload, not delete the user's photo from iCloud")
    }

    /// The re-upload does not always run on the coordinator that queued the delete.
    /// Moving an album back into iCloud drives a `CloudKitSyncCoordinator` the
    /// migration manager builds for itself, while the delete was queued by the
    /// registry's long-lived coordinator for the same album. That one wakes up on
    /// its next sync — and used to hard-delete the records the migration had just
    /// re-published. Verified on the rig, where a migration reporting COMPLETED was
    /// followed by three `purge ok` lines and an album showing zero items.
    ///
    /// Making both halves of the delete bookkeeping process-wide is what fixes it:
    /// republishing a record name clears the pending delete AND the known-deleted
    /// mark for that name whichever coordinator does the publishing, so no "is it
    /// still there?" round trip is needed. The mark is the half that was still per
    /// instance — the registry coordinator went on refusing every read of a photo
    /// the migration had just put back.
    func testARepublishedRecordCancelsAPendingDeleteQueuedByAnotherCoordinator() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (registryCoord, _, _) = makeCoordinator(store: store, deleteQueue: queue)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await registryCoord.sync(albumID: "a1")

        store.deleteErrorOnce = CloudKitMediaStoreError.retry(after: 1)
        try await registryCoord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(queue.pending(), ["m1"])

        let (migrationCoord, _, _) = makeCoordinator(store: store, deleteQueue: queue)
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)
        _ = try await migrationCoord.upload(upload, progress: { _ in })

        XCTAssertTrue(queue.pending().isEmpty,
                      "Republishing the name must cancel the delete the other coordinator queued")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await registryCoord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"],
                       "Only the failed move-out delete — the fresh copy must never be deleted")

        _ = try await registryCoord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
    }

    /// The two halves of a delete move together, or they do not move.
    ///
    /// Claiming a delete sets the mark reads fail closed on and queues the server
    /// delete; republishing the name drops both. Done as separate calls they can
    /// interleave — the republish clears the mark, a claim sets it and queues, the
    /// republish's queue drop lands last — leaving the record marked but unqueued:
    /// refused for reads for the rest of the session, and never retried by any
    /// sync. That is the original symptom, resurrected under a race.
    ///
    /// Pinned by forcing the interleaving rather than racing for it: the seam runs
    /// in the middle of a `forgetDeletion`, and from there a claim of the same name
    /// is attempted from another thread. While the pair is atomic that claim cannot
    /// complete — it blocks on the lock the republish holds — so the window the bug
    /// needs does not exist. Split the pair into two acquisitions and the claim
    /// lands inside the window every time.
    func testAPairedUpdateCannotBeInterleavedByAnother() {
        let queue = makeDeleteQueue()

        queue.claimDeletion(of: "m1", queueRemoteDelete: true)
        assertNoInterleaving(of: queue,
                             outer: { queue.forgetDeletion(of: "m1") },
                             interloper: { queue.claimDeletion(of: "m1", queueRemoteDelete: true) })

        assertNoInterleaving(of: queue,
                             outer: { queue.claimDeletion(of: "m1", queueRemoteDelete: true) },
                             interloper: { queue.forgetDeletion(of: "m1") })
    }

    /// Runs `outer` with a one-shot seam installed in the middle of it, and from
    /// that seam attempts `interloper` on another thread. While paired updates are
    /// atomic the interloper cannot finish inside the window — it blocks on the
    /// lock `outer` holds — so the assertion is deterministic rather than a race
    /// the test hopes to catch.
    private func assertNoInterleaving(of queue: CloudKitMediaDeleteQueue,
                                      outer: () -> Void,
                                      interloper: @escaping @Sendable () -> Void,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        // Two semaphores, not one: the seam consumes the first, and the join below
        // needs a signal of its own or it waits for one already taken.
        let landed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let landedMidUpdate = MidUpdateWitness()

        CloudKitMediaDeleteQueue.pairedUpdateSeam = {
            CloudKitMediaDeleteQueue.pairedUpdateSeam = nil
            DispatchQueue.global().async {
                interloper()
                landed.signal()
                finished.signal()
            }
            if landed.wait(timeout: .now() + 0.5) == .success { landedMidUpdate.record() }
        }
        defer { CloudKitMediaDeleteQueue.pairedUpdateSeam = nil }

        outer()
        finished.wait()

        XCTAssertFalse(landedMidUpdate.landed,
                       "A paired update completed while another was between its two halves",
                       file: file, line: line)
        let state = queue.deletionState(of: "m1")
        XCTAssertEqual(state.knownDeleted, state.queued,
                       "However the two updates ordered, the halves must agree",
                       file: file, line: line)
    }

    /// Two queues over one suite are one queue. The durable half comes from the
    /// suite's defaults and the session half from the same suite's marks, so a
    /// caller cannot end up with a private pending-delete list and the shared
    /// marks — the split that would let one coordinator queue a delete another
    /// never learns to stop refusing.
    func testQueuesOverTheSameSuiteShareBothHalves() {
        let suite = "ck-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(suite)
        let a = CloudKitMediaDeleteQueue(suiteName: suite)
        let b = CloudKitMediaDeleteQueue(suiteName: suite)

        a.claimDeletion(of: "m1", queueRemoteDelete: true)

        let seenByB = b.deletionState(of: "m1")
        XCTAssertTrue(seenByB.queued, "The durable half must be the suite's")
        XCTAssertTrue(seenByB.knownDeleted, "The session half must be the suite's too")

        b.forgetDeletion(of: "m1")
        let seenByA = a.deletionState(of: "m1")
        XCTAssertFalse(seenByA.queued)
        XCTAssertFalse(seenByA.knownDeleted, "A republish on either instance clears both halves")
    }

    /// A delete confirmed against the server must only clear the intent it was
    /// issued for. The record can be republished and deleted again while the first
    /// delete is in flight, and an unconditional drop then removes the SECOND
    /// delete's queue entry — leaving the record marked, still live in the zone,
    /// and refused for reads for the rest of the session with nothing to retry.
    func testAConfirmedDeleteCannotClearTheIntentOfALaterOne() async {
        let queue = makeDeleteQueue()

        let first = queue.claimDeletion(of: "m1", queueRemoteDelete: true)
        queue.forgetDeletion(of: "m1")
        queue.claimDeletion(of: "m1", queueRemoteDelete: true)

        queue.confirmDelete(of: "m1", claimedAs: first)

        let state = queue.deletionState(of: "m1")
        XCTAssertTrue(state.knownDeleted, "The second delete still owns the record")
        XCTAssertTrue(state.queued,
                      "A stale confirmation must not dequeue the delete that superseded it")
    }

    /// The guard the fix above must NOT weaken: a delete issued while the bytes are
    /// genuinely in flight still wins, and the record that lands is reclaimed.
    func testADeleteThatLandsDuringAnUploadStillWins() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        store.onUploadStarted = { [weak coord] in
            guard let coord else { return }
            _ = try? await coord.remove(recordName: "m1", albumID: "a1")
        }
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)

        do {
            _ = try await coord.upload(upload, progress: { _ in })
            XCTFail("An upload that lost the race to a delete must not report success")
        } catch let error as CloudKitMediaStoreError {
            guard case .cancelled = error else { return XCTFail("Wrong error: \(error)") }
        }

        let entries = await ids(index)
        XCTAssertTrue(entries.isEmpty, "A photo deleted mid-upload must not be resurrected in the index")
        XCTAssertEqual(store.deleteCalls.filter { $0 == "m1" }.count, 2,
                       "Both the delete itself and the record that landed after it must be removed")
    }

    // MARK: - Drain against a republish

    /// The drain works from a snapshot of the queue, and an album moved back into
    /// iCloud republishes the same record names while it runs. A record uploaded
    /// after the snapshot is live again, and its local original is deleted once it
    /// verifies — so the stale entry must not delete it.
    func testDrainSkipsRecordRepublishedAfterSnapshot() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue)
        let earlier = photoUpload("a")
        let republished = photoUpload("x")
        XCTAssertLessThan(earlier.recordName, republished.recordName, "Precondition: the drain reaches the gated entry first")

        queue.claimDeletion(of: earlier.recordName, queueRemoteDelete: true)
        queue.claimDeletion(of: republished.recordName, queueRemoteDelete: true)
        let gate = AsyncGate()
        store.deleteGates[earlier.recordName] = gate

        let sync = Task { try await coord.sync(albumID: "a1") }
        await gate.waitUntilEntered()

        _ = try await coord.upload(republished, progress: { _ in })
        await gate.release()
        try await sync.value

        XCTAssertEqual(store.deleteCalls, [earlier.recordName],
                       "The drain deleted a record republished after its snapshot")
        XCTAssertTrue(queue.pending().isEmpty)
    }

    /// The same race, landing between the two legs of one entry: the `EncMedia`
    /// delete is already on the wire when the record is republished. The upload
    /// waits for that delete, and the chunk leg — which would delete the
    /// republished video's chunks, whose record names are the same — never runs.
    func testDrainSkipsChunkDeleteWhenRecordRepublishedBetweenLegs() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let chunks = ChunkDeleteRecorder()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue, chunkStore: chunks)
        let republished = photoUpload("x")
        let name = republished.recordName

        queue.claimDeletion(of: name, chunkCount: 3, queueRemoteDelete: true)
        let gate = AsyncGate()
        store.deleteGates[name] = gate

        let sync = Task { try await coord.sync(albumID: "a1") }
        await gate.waitUntilEntered()

        let upload = Task { try await coord.upload(republished, progress: { _ in }) }
        try await waitUntil { !queue.pending().contains(name) }
        XCTAssertFalse(store.callOrder.contains(.upload(recordName: name)),
                       "The upload must wait for the delete already in flight, not race it to the server")

        await gate.release()
        try await sync.value
        _ = try await upload.value

        let chunkDeletes = await chunks.deletedNames
        XCTAssertEqual(chunkDeletes, [], "The chunk leg ran after the record was republished")
        XCTAssertEqual(store.deleteCalls, [name])
        let order = store.callOrder.filter { $0 == .delete(recordName: name) || $0 == .upload(recordName: name) }
        XCTAssertEqual(order, [.delete(recordName: name), .upload(recordName: name)],
                       "The republish must land after the in-flight delete, or the delete removes it")
        XCTAssertTrue(queue.pending().isEmpty)
    }

    /// The guard on the two tests above: an entry nothing has republished drains
    /// exactly as before — the record, then its chunks, and `.notFound` counts as
    /// done.
    func testDrainStillDeletesCurrentEntries() async throws {
        let store = MockCloudKitMediaStore()
        let queue = makeDeleteQueue()
        let chunks = ChunkDeleteRecorder()
        let (coord, _, _) = makeCoordinator(store: store, deleteQueue: queue, chunkStore: chunks)
        let gone = photoUpload("a").recordName
        let photo = photoUpload("b").recordName
        let video = photoUpload("c").recordName

        queue.claimDeletion(of: gone, queueRemoteDelete: true)
        queue.claimDeletion(of: photo, queueRemoteDelete: true)
        queue.claimDeletion(of: video, chunkCount: 4, queueRemoteDelete: true)
        store.deleteErrorOnce = CloudKitMediaStoreError.notFound

        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, [gone, photo, video])
        let chunkDeletes = await chunks.deletes
        XCTAssertEqual(chunkDeletes.map(\.mediaRecordName), [video])
        XCTAssertEqual(chunkDeletes.map(\.chunkCount), [4])
        XCTAssertTrue(queue.pending().isEmpty, "Every current entry, including the one already gone, is confirmed")

        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, [gone, photo, video], "A drained delete is not retried")
    }

    func testUploadEntryUsesCreatedAtForSorting() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)
        let captured = Date(timeIntervalSince1970: 555)
        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "u1", mediaType: .photo,
                                         createdAt: captured, sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/x.blob"),
                                         encryptedThumbURL: URL(fileURLWithPath: "/tmp/x.thumb"))

        _ = try await coord.upload(upload, progress: { _ in })

        let entry = (await index.load()?.entries ?? []).first { $0.id == "u1" }
        XCTAssertEqual(entry?.dateEncrypted, captured)
    }

    /// A wiped/missing index while a change token is still set must force a full
    /// resync — otherwise the token skips historical records and the album stays empty.
    func testSyncRebuildsIndexWhenWipedButTokenExists() async throws {
        let store = MockCloudKitMediaStore()
        store.hasChangeTokenValue = true
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.resetChangeTokenCount, 1, "Wiped index with a token must force a full resync")
        let rebuilt = await ids(index)
        XCTAssertEqual(rebuilt, ["m1"])
    }

    /// An intact index must NOT force a resync just because a token exists.
    func testSyncDoesNotResetTokenWhenIndexPresent() async throws {
        let store = MockCloudKitMediaStore()
        store.hasChangeTokenValue = true
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        let resetsAfterFirst = store.resetChangeTokenCount
        XCTAssertEqual(resetsAfterFirst, 1, "A missing index alongside a live token forces exactly one reset")

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.resetChangeTokenCount, resetsAfterFirst, "An intact index must not force a resync")
    }

    /// Concurrent syncs on one coordinator must coalesce, not each run a full
    /// load–merge–save that races the index and re-advances the token.
    func testConcurrentSyncsAreCoalesced() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchChangesDelayNanos = 50_000_000
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        async let s1: Void = coord.sync(albumID: "a1")
        async let s2: Void = coord.sync(albumID: "a1")
        async let s3: Void = coord.sync(albumID: "a1")
        async let s4: Void = coord.sync(albumID: "a1")
        _ = try await [s1, s2, s3, s4]

        XCTAssertGreaterThanOrEqual(store.fetchChangesCount, 1, "Coalescing four syncs into none is not coalescing")
        XCTAssertLessThanOrEqual(store.fetchChangesCount, 2, "Overlapping syncs must coalesce, not run once each")
        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "The coalesced pass still applies the change feed")
    }

    /// A coalesced sync must still WAIT for the in-flight run to finish (and pick up
    /// the caller's request), not return early before changes are applied.
    func testCoalescedSyncWaitsForCompletion() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchChangesDelayNanos = 80_000_000
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        let first = Task { try await coord.sync(albumID: "a1") }
        try await Task.sleep(nanoseconds: 15_000_000)
        try await coord.sync(albumID: "a1")

        let entries = await ids(index)
        XCTAssertEqual(entries, ["m1"], "A coalesced sync must not return before the index is applied")
        try await first.value
    }

    /// The registry hands back one coordinator per album id so the active album and
    /// the push fan-out share in-memory state.
    func testCoordinatorRegistryReturnsSameInstance() async {
        let registry = CloudKitCoordinatorRegistry()
        let make: () -> CloudKitSyncCoordinator = {
            CloudKitSyncCoordinator(albumID: "a1", store: MockCloudKitMediaStore(),
                                    cache: CloudKitBlobCache.shared, indexStore: self.makeIndexStore(),
                                    deleteQueue: self.makeDeleteQueue())
        }
        let c1 = await registry.coordinator(forAlbumID: "a1", make: make)
        let c2 = await registry.coordinator(forAlbumID: "a1", make: make)
        XCTAssertTrue(c1 === c2, "Same album id must reuse one coordinator")
    }

    /// After an `upload`, reading the index must serve from the store's warm cache
    /// rather than re-decrypting the file on every access — the asymmetry that the
    /// cloud path used to have (no cache at all) is gone now that the coordinator
    /// mutates through the stateful store.
    func testUploadThenReadServesFromCacheWithoutReload() async throws {
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString).encindex")
        let index = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32), indexURL: url)
        let store = MockCloudKitMediaStore()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: makeCache(),
                                            indexStore: index, bus: FileOperationBus(),
                                            deleteQueue: makeDeleteQueue())

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "u1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/x.blob"),
                                         encryptedThumbURL: URL(fileURLWithPath: "/tmp/x.thumb"))
        _ = try await coord.upload(upload, progress: { _ in })

        let warm = await index.current()
        XCTAssertEqual(warm?.entries.map(\.id), ["u1"])
        try FileManager.default.removeItem(at: url)
        let afterDelete = await index.current()
        XCTAssertEqual(afterDelete?.entries.map(\.id), ["u1"],
                       "the cloud read path must serve from the warm cache, not re-decrypt the file each time")
    }

    private final class CapturedIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ id: String) { lock.lock(); storage.append(id); lock.unlock() }
        func append(contentsOf ids: [String]) { lock.lock(); storage.append(contentsOf: ids); lock.unlock() }
        func clear() { lock.lock(); storage.removeAll(); lock.unlock() }
    }

    // MARK: - A local save during a sync

    /// A video registered while a sync is out on the network must still be in the
    /// album when that sync finishes.
    ///
    /// `performSync` reads the index into a local array, awaits the whole change
    /// feed, and then writes that array back. Because the coordinator is an actor,
    /// it suspends at every one of those awaits, so `registerLocally` interleaves —
    /// and the write-back, built from the pre-fetch snapshot, drops the entry it
    /// never saw. Nothing throws and nothing is logged; the album simply renders
    /// empty while the ciphertext, the upload and the server record are all fine.
    func testSaveDuringSyncSurvivesTheSyncsIndexWrite() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        let gate = AsyncGate()
        store.fetchChangesGate = gate

        let (coord, index, _) = makeCoordinator(store: store)

        let sync = Task { try await coord.sync(albumID: "a1") }
        await gate.waitUntilEntered()

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/m1.blob"),
                                         encryptedThumbURL: nil)
        try await coord.registerLocally(upload)
        let afterSave = await ids(index)
        XCTAssertEqual(afterSave, ["m1"],
                       "Precondition: the save must reach the index before the sync writes back")

        await gate.release()
        try await sync.value

        let afterSync = await ids(index)
        XCTAssertEqual(afterSync, ["m1"],
                       "The sync wrote back the index it read before the save and dropped it — "
                       + "the media is uploaded and server-confirmed, but the album renders empty")
    }

    // MARK: - Residency

    /// The storage figure on the info screen reads every chunk of a video. Reading
    /// them must not mark them used: a 512-chunk video would otherwise jump the
    /// whole queue and the byte cap would evict everything the user is still
    /// watching instead.
    func testCachedBytesOverChunksDoesNotSkewTheCacheLRU() async throws {
        let store = MockCloudKitMediaStore()
        let index = makeIndexStore()
        let cache = CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-lru"),
                                      maxBytes: 200)
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: FileOperationBus(), deleteQueue: makeDeleteQueue())
        let videoMeta = CloudKitMediaMetadata(recordName: "vid#1",
                                              albumID: "a1",
                                              mediaID: "vid",
                                              mediaType: .video,
                                              createdAt: Date(timeIntervalSince1970: 100),
                                              sizeBytes: 120,
                                              creationDeviceID: "device",
                                              schemaVersion: 1,
                                              keyFingerprint: "",
                                              recordChangeTag: "tag-1",
                                              chunkCount: 3)
        store.changeSet = CloudKitChangeSet(changed: [videoMeta], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        var chunkURLs: [URL] = []
        for chunk in 0..<3 {
            let name = ChunkedBlobSchema.chunkRecordName(mediaRecordName: "vid#1", index: chunk)
            chunkURLs.append(try await cache.store(recordName: name, changeTag: "tag-1", albumID: "a1",
                                                   from: cacheSourceFile(bytes: 40)))
        }
        let photoURL = try await cache.store(recordName: "photo#1", changeTag: nil, albumID: "a1",
                                             from: cacheSourceFile(bytes: 40))

        let bytes = await coord.cachedBytes(recordName: "vid#1")
        XCTAssertEqual(bytes, 120, "Every cached chunk counts toward the video's local size")

        _ = try await cache.store(recordName: "fresh", changeTag: nil, albumID: "a1",
                                  from: cacheSourceFile(bytes: 60))

        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkURLs[0].path),
                       "The oldest chunk is the least recently used entry and must be the one evicted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path),
                      "Reading the video's size must not push a more recently used blob out of the cache")
    }

    // MARK: - Info-screen round trips

    /// A record name for one component, spelled the way every production caller
    /// spells it.
    private func componentName(_ mediaID: String, _ type: MediaType) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: type)
    }

    private func geometryMeta(recordName: String,
                              mediaID: String,
                              type: MediaType,
                              sizeBytes: Int64 = 10,
                              chunkCount: Int = 0,
                              encHeader: Data? = nil) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName,
                              albumID: "a1",
                              mediaID: mediaID,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: sizeBytes,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              keyFingerprint: stubKeyFingerprint,
                              recordChangeTag: "tag-\(recordName)",
                              chunkCount: chunkCount,
                              plaintextLength: chunkCount > 0 ? 1_000 : 0,
                              encHeader: encHeader)
    }

    /// Opening the info screen on a photo used to fetch the photo's record just to
    /// be told what the record name already says. Only the count can show it: the
    /// answer was `nil` before and after.
    func testChunkGeometryForAPhotoCostsNoRoundTrip() async throws {
        let store = MockCloudKitMediaStore()
        let photo = componentName("m1", .photo)
        store.metadataToReturn = [geometryMeta(recordName: photo, mediaID: "m1", type: .photo)]
        let (coord, _, _) = makeCoordinator(store: store)

        let info = try await coord.chunkedBlobInfo(recordName: photo)

        XCTAssertNil(info, "a photo is never chunked")
        XCTAssertEqual(store.fetchRecordMetadataCount, 0,
                       "a photo cannot be chunked, so asking the server what its chunk count is buys nothing")
    }

    /// The info screen is re-opened constantly. A monolithic video used to answer
    /// from the server every single time, because "not chunked" was stored as the
    /// absence of an entry — the same state as "never looked".
    func testReopeningAMonolithicVideoDoesNotRefetchItsGeometry() async throws {
        let store = MockCloudKitMediaStore()
        let video = componentName("v1", .video)
        store.metadataToReturn = [geometryMeta(recordName: video, mediaID: "v1", type: .video)]
        let (coord, _, _) = makeCoordinator(store: store)

        var info = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertNil(info)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1, "the first look has to ask")

        info = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertNil(info, "the record is still monolithic")
        XCTAssertEqual(store.fetchRecordMetadataCount, 1,
                       "the monolithic answer was not kept, so every re-open pays for it again")
    }

    /// Delta sync already carries every record's chunk count. Once it has run,
    /// nothing should have to ask again — for a monolithic record either.
    func testASyncThatSawAMonolithicVideoLeavesNothingToFetch() async throws {
        let store = MockCloudKitMediaStore()
        let video = componentName("v1", .video)
        let record = geometryMeta(recordName: video, mediaID: "v1", type: .video)
        store.changeSet = CloudKitChangeSet(changed: [record], deleted: [], token: nil, moreComing: false)
        store.metadataToReturn = [record]
        let (coord, _, _) = makeCoordinator(store: store)

        try await coord.sync(albumID: "a1")
        let fetchesAfterSync = store.fetchRecordMetadataCount

        let info = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertNil(info)

        XCTAssertEqual(store.fetchRecordMetadataCount, fetchesAfterSync,
                       "sync already knew this record is monolithic; asking again is a wasted round trip")
    }

    /// The staleness hazard, closed at the source: a record that is not on the
    /// server yet reads as absent, and an upload in flight looks exactly like
    /// that. Banking "monolithic" from it would answer wrongly for the rest of the
    /// session — so nothing is banked, and the next look asks again.
    func testAnAbsentRecordIsNeverBankedAsMonolithic() async throws {
        let store = MockCloudKitMediaStore()
        let video = componentName("v1", .video)
        let (coord, _, _) = makeCoordinator(store: store)

        let absent = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertNil(absent)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1)

        store.metadataToReturn = [geometryMeta(recordName: video, mediaID: "v1", type: .video,
                                                chunkCount: 4, encHeader: Data([0xE3]))]

        let info = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertEqual(info?.chunkCount, 4,
                       "a record that did not exist yet must not be remembered as monolithic")
        XCTAssertEqual(store.fetchRecordMetadataCount, 2, "the second look has to ask, and did")
    }

    /// The optimization must not cost playback resolution: a genuinely chunked
    /// video resolves on the first look, and the banked positive answer serves the
    /// second without asking again.
    func testAChunkedVideoStillResolvesAndIsThenAnsweredFromMemory() async throws {
        let store = MockCloudKitMediaStore()
        let video = componentName("v1", .video)
        let header = Data([0xE3, 0x01, 0x02])
        store.metadataToReturn = [geometryMeta(recordName: video, mediaID: "v1", type: .video,
                                                chunkCount: 7, encHeader: header)]
        let (coord, _, _) = makeCoordinator(store: store)

        let first = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertEqual(first?.chunkCount, 7)
        XCTAssertEqual(first?.encHeader, header, "streaming opens on these bytes and nothing else")

        let second = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertEqual(second?.chunkCount, 7)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1)
    }

    /// One info screen asks two questions about the same record — what its
    /// geometry is and how many bytes it occupies — and the metadata fetch answers
    /// both. It used to throw the size away and fetch the record a second time.
    func testAVideoInfoScreenFetchesTheRecordOnceNotTwice() async throws {
        let store = MockCloudKitMediaStore()
        let video = componentName("v1", .video)
        store.metadataToReturn = [geometryMeta(recordName: video, mediaID: "v1", type: .video,
                                                sizeBytes: 4_096)]
        let (coord, _, _) = makeCoordinator(store: store, sizeSidecar: makeSizeSidecar())

        let info = try await coord.chunkedBlobInfo(recordName: video)
        XCTAssertNil(info)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1, "the geometry look has to ask once")

        let bytes = await coord.remoteBytes(recordName: video)

        XCTAssertEqual(bytes, 4_096)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1,
                       "the size came back with the geometry; fetching the same record again for it is the round trip this fixes")
    }

    /// And the fetch a photo does still pay — its size — is banked too, so the
    /// second open of the same info screen asks for nothing at all.
    func testRemoteBytesBanksTheSizeItFetched() async throws {
        let store = MockCloudKitMediaStore()
        let photo = componentName("m1", .photo)
        store.metadataToReturn = [geometryMeta(recordName: photo, mediaID: "m1", type: .photo,
                                                sizeBytes: 777)]
        let (coord, _, _) = makeCoordinator(store: store, sizeSidecar: makeSizeSidecar())

        var bytes = await coord.remoteBytes(recordName: photo)
        XCTAssertEqual(bytes, 777)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1)

        bytes = await coord.remoteBytes(recordName: photo)

        XCTAssertEqual(bytes, 777)
        XCTAssertEqual(store.fetchRecordMetadataCount, 1,
                       "a size the sidecar has already been told is not worth a second fetch")
    }

    private func cacheSourceFile(bytes: Int) throws -> URL {
        let url = tempRoot.appendingPathComponent("blob-source-\(UUID().uuidString)")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private final class TypeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MediaType] = []
        var values: [MediaType] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(contentsOf types: [MediaType]) { lock.lock(); storage.append(contentsOf: types); lock.unlock() }
    }

    // MARK: - Moved-away (re-parented) records

    /// A helper that builds metadata with a foreign albumID.
    private func foreignMeta(_ name: String,
                             albumID: String = "a2",
                             mediaID: String? = nil,
                             type: MediaType = .photo,
                             tag: String? = "tag-1") -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: name,
                              albumID: albumID,
                              mediaID: mediaID ?? name,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: 10,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              recordChangeTag: tag)
    }

    func testChangedRecordNowOwnedByAnotherAlbumIsDroppedFromIndex() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            if case .delete(let medias) = operation { deleted.append(contentsOf: medias.map { $0.id }) }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        // Seed m1 into this album's index.
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        let seeded = await ids(index)
        XCTAssertEqual(seeded, ["m1"], "m1 must be in the index before the move")

        // m1 now arrives with albumID "a2" — it moved to another album.
        store.changeSet = CloudKitChangeSet(changed: [foreignMeta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let afterMove = await ids(index)
        XCTAssertTrue(afterMove.isEmpty, "A record that moved to another album must leave the source index")
        XCTAssertEqual(deleted.values, ["m1"], "A moved-away record emits a delete event on the bus")
    }

    func testMovedAwayRecordEvictsCacheAndSidecarSize() async throws {
        let store = MockCloudKitMediaStore()
        let sidecar = makeSizeSidecar()
        let (coord, index, _) = makeCoordinator(store: store, sizeSidecar: sidecar)

        // Seed m1, cache a blob, and record its size.
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        let cachedBefore = await coord.isBlobCached(recordName: "m1")
        XCTAssertTrue(cachedBefore, "The blob must be cached before the move")

        // Move m1 to another album.
        store.changeSet = CloudKitChangeSet(changed: [foreignMeta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let cachedAfter = await coord.isBlobCached(recordName: "m1")
        XCTAssertFalse(cachedAfter, "A moved-away record's ciphertext must be evicted from the blob cache")

        let afterMove = await ids(index)
        XCTAssertTrue(afterMove.isEmpty, "m1 must be gone from the index")
    }

    func testMovedAwayLivePhotoHalfKeepsEntryAndEmitsRefresh() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            switch operation {
            case .create(let media): created.append(media.id)
            case .delete(let medias): deleted.append(contentsOf: medias.map { $0.id })
            case .move, .albumCoverChanged: break
            }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index,
                                            bus: bus, deleteQueue: makeDeleteQueue())

        // Seed a Live Photo with both components in this album.
        store.changeSet = CloudKitChangeSet(changed: [
            metaComponent(recordName: "live#0", mediaID: "live", type: .photo),
            metaComponent(recordName: "live#1", mediaID: "live", type: .video)
        ], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let seeded = await ids(index)
        XCTAssertEqual(seeded, ["live"], "Both components produce one index entry")

        // Clear bus events from the seed phase so we only see the move's events.
        created.clear()
        deleted.clear()

        // Move only the video component to another album.
        let movedVideo = CloudKitMediaMetadata(recordName: "live#1",
                                               albumID: "a2",
                                               mediaID: "live",
                                               mediaType: .video,
                                               createdAt: Date(timeIntervalSince1970: 100),
                                               sizeBytes: 10,
                                               creationDeviceID: "device",
                                               schemaVersion: 1,
                                               recordChangeTag: "tag-moved")
        store.changeSet = CloudKitChangeSet(changed: [movedVideo], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let afterHalfMove = await ids(index)
        XCTAssertEqual(afterHalfMove, ["live"], "The photo half survives — the entry stays")
        XCTAssertTrue(deleted.values.isEmpty, "No delete event — the entry was not fully removed")
        XCTAssertEqual(created.values, ["live"], "A refresh (create) event is emitted for the surviving half")
    }

    func testForeignRecordNeverIndexedIsStillSkipped() async throws {
        let store = MockCloudKitMediaStore()
        let bus = FileOperationBus()
        let created = CapturedIDs()
        let deleted = CapturedIDs()
        let cancellable = bus.operations.sink { operation in
            switch operation {
            case .create(let media): created.append(media.id)
            case .delete(let medias): deleted.append(contentsOf: medias.map { $0.id })
            case .move, .albumCoverChanged: break
            }
        }
        defer { cancellable.cancel() }

        let (coord, index, _) = makeCoordinator(store: store, bus: bus)

        // A record for a different album that was never in this album's index.
        store.changeSet = CloudKitChangeSet(changed: [foreignMeta("foreign1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let afterSync = await ids(index)
        XCTAssertTrue(afterSync.isEmpty, "A foreign record must not be added to this album's index")
        XCTAssertTrue(created.values.isEmpty, "No create event for a foreign record")
        XCTAssertTrue(deleted.values.isEmpty, "No delete event for a foreign record")
    }
}
