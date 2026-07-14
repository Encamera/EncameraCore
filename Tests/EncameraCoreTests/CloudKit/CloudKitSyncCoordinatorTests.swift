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
                                 bus: FileOperationBus = FileOperationBus())
        -> (CloudKitSyncCoordinator, MediaIndexStore, CloudKitBlobCache) {
        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)
        return (coord, index, cache)
    }

    private func meta(_ name: String,
                      type: MediaType = .photo,
                      tag: String? = "tag-1",
                      deletedAt: Date? = nil) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: name,
                              albumID: "a1",
                              mediaID: name,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: 10,
                              creationDeviceID: "device",
                              deletedAt: deletedAt,
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
                              deletedAt: nil,
                              schemaVersion: 1,
                              recordChangeTag: "tag-\(recordName)")
    }

    private func ids(_ store: MediaIndexStore) async -> [String] {
        (await store.load()?.entries ?? []).map { $0.id }.sorted()
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
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let result = await ids(index)
        XCTAssertTrue(result.isEmpty)
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
            // expected
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
        store.fetchBlobDelayNanos = 50_000_000  // 50ms to force overlap
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
        try await coord.evictAll(olderThan: Date().addingTimeInterval(60))   // future => evicts all
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })

        XCTAssertEqual(store.fetchBlobCount, 2)
    }

    // MARK: - Cross-device delete

    func testTombstoneThenDeleteOrdering() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        try await coord.remove(recordName: "m1", albumID: "a1")
        XCTAssertEqual(store.tombstoneCalls, ["m1"])
        XCTAssertEqual(store.deleteCalls, [], "Hard delete is deferred to the follow-up pass")
        let afterRemove = await ids(index)
        XCTAssertTrue(afterRemove.isEmpty)

        // A delete that lands mid-fetch wins.
        do {
            _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
            XCTFail("Expected notFound for a tombstoned record")
        } catch let error as CloudKitMediaStoreError {
            guard case .notFound = error else { return XCTFail("Wrong error: \(error)") }
        }

        // Follow-up sync issues the hard delete.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"])
    }

    func testObservedTombstoneEnqueuesHardPurge() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, index, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // Another device tombstoned m1 and died before its purge pass; this device
        // only OBSERVES the tombstone via delta sync. It must enqueue and issue the
        // hard purge itself, or the record's full-size blob sits in the user's
        // iCloud quota forever.
        store.changeSet = CloudKitChangeSet(changed: [meta("m1", deletedAt: Date())], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(store.deleteCalls, ["m1"], "An observed tombstone must trigger the hard purge")
        let result = await ids(index)
        XCTAssertTrue(result.isEmpty)
    }

    func testCachedBlobSurvivesRelaunchBeforeTagMapRepopulates() async throws {
        let store = MockCloudKitMediaStore()
        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: FileOperationBus())

        store.changeSet = CloudKitChangeSet(changed: [meta("m1", tag: "t1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        _ = try await coord.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)

        // "Relaunch": a fresh coordinator over the SAME persisted cache, before any
        // delta sync has repopulated its in-memory change-tag map. The persisted
        // entry must be trusted (nil expectation), not re-downloaded wholesale.
        let relaunched = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: FileOperationBus())
        _ = try await relaunched.ensureBlobLocal(recordName: "m1", albumID: "a1", progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "A persisted cache entry with no newer known tag must be a hit after relaunch")
    }

    // MARK: - Push / notifications

    func testStartObservingSkipsSubscriptionWhenNoAccount() async {
        let store = MockCloudKitMediaStore()
        store.accountAvailableValue = false
        let (coord, _, _) = makeCoordinator(store: store)

        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionCount, 0)

        store.accountAvailableValue = true
        await coord.startObserving()
        XCTAssertEqual(store.registerSubscriptionCount, 1)
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
            case .move: break
            }
        }
        defer { cancellable.cancel() }

        let index = makeIndexStore()
        let cache = makeCache()
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        // First add m1 and m2, then delete m2 — a delete only fires for an item this
        // album actually held (deletes are album-scoped against the shared zone).
        store.changeSet = CloudKitChangeSet(changed: [meta("m1"), meta("m2")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["m2"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertEqual(created.values, ["m1", "m2"])
        XCTAssertEqual(deleted.values, ["m2"])
    }

    // MARK: - Bugbot regressions

    /// A stale hard-delete (record already gone elsewhere) must not abort the whole sync.
    func testSyncToleratesAlreadyDeletedRecordDuringPurge() async throws {
        let store = MockCloudKitMediaStore()
        let (coord, _, _) = makeCoordinator(store: store)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")
        try await coord.remove(recordName: "m1", albumID: "a1")   // tombstone + queue purge

        // The server no longer has it: the hard delete maps to notFound.
        store.deleteError = CloudKitMediaStoreError.notFound
        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)

        // Must not throw, and must not keep retrying forever.
        try await coord.sync(albumID: "a1")
        try await coord.sync(albumID: "a1")
        XCTAssertEqual(store.deleteCalls, ["m1"], "A notFound purge should be dropped, not retried")
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

        // The photo component is removed from the zone; the video remains.
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

        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["live#0", "live#1"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        let entry = (await index.load()?.entries ?? []).first { $0.id == "live" }
        XCTAssertNil(entry, "Both components gone => entry removed")
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
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t-\(name)")
        }
        store.changeSet = CloudKitChangeSet(changed: [
            dated("old", Date(timeIntervalSince1970: 100)),
            dated("new", Date(timeIntervalSince1970: 200))
        ], deleted: [], token: nil, moreComing: false)

        try await coord.sync(albumID: "a1")

        let entries = await index.load()?.entries ?? []
        XCTAssertNotNil(entries.first { $0.id == "new" }?.dateEncrypted, "Synced entries need an encrypted date")
        let sorted = MediaIndex(entries: entries).sortedFilteredEntries(sortBy: .dateEncrypted(ascending: false), filterBy: .all)
        XCTAssertEqual(sorted.map { $0.id }, ["new", "old"], "Newest capture first")
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
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")   // first time: create
        try await coord.sync(albumID: "a1")   // already present: no new create

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
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        // A delete for "other#0" — a record from a different album we never indexed.
        store.changeSet = CloudKitChangeSet(changed: [], deleted: ["other#0"], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")

        XCTAssertTrue(deleted.values.isEmpty, "Deletes for other albums must be ignored")
        let remaining = await ids(index)
        XCTAssertEqual(remaining, ["m1"], "Our album's index must be untouched")
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
        let coord = CloudKitSyncCoordinator(albumID: "a1", store: store, cache: cache, indexStore: index, bus: bus)

        store.changeSet = CloudKitChangeSet(changed: [metaComponent(recordName: "live#0", mediaID: "live", type: .photo)], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")   // photo arrives -> create
        store.changeSet = CloudKitChangeSet(changed: [metaComponent(recordName: "live#1", mediaID: "live", type: .video)], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")   // video merges in -> refresh

        XCTAssertEqual(created.values, ["live", "live"], "Adding a component must refresh the gallery")
    }

    /// A locally uploaded item must sort consistently with synced items: use the
    /// capture date for `dateEncrypted`, not the wall clock at upload time.
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
        let (coord, index, _) = makeCoordinator(store: store)   // fresh index file => load() == nil

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
        try await coord.sync(albumID: "a1")        // index missing first time => one reset
        let resetsAfterFirst = store.resetChangeTokenCount

        store.changeSet = CloudKitChangeSet(changed: [], deleted: [], token: nil, moreComing: false)
        try await coord.sync(albumID: "a1")        // index now present => no extra reset

        XCTAssertEqual(store.resetChangeTokenCount, resetsAfterFirst, "An intact index must not force a resync")
    }

    /// Concurrent syncs on one coordinator must coalesce, not each run a full
    /// load–merge–save that races the index and re-advances the token.
    func testConcurrentSyncsAreCoalesced() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchChangesDelayNanos = 50_000_000  // 50ms so the calls overlap
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, _, _) = makeCoordinator(store: store)

        async let s1: Void = coord.sync(albumID: "a1")
        async let s2: Void = coord.sync(albumID: "a1")
        async let s3: Void = coord.sync(albumID: "a1")
        async let s4: Void = coord.sync(albumID: "a1")
        _ = try await [s1, s2, s3, s4]

        XCTAssertLessThanOrEqual(store.fetchChangesCount, 2, "Overlapping syncs must coalesce, not run once each")
    }

    /// A coalesced sync must still WAIT for the in-flight run to finish (and pick up
    /// the caller's request), not return early before changes are applied.
    func testCoalescedSyncWaitsForCompletion() async throws {
        let store = MockCloudKitMediaStore()
        store.fetchChangesDelayNanos = 80_000_000   // 80ms
        store.changeSet = CloudKitChangeSet(changed: [meta("m1")], deleted: [], token: nil, moreComing: false)
        let (coord, index, _) = makeCoordinator(store: store)

        let first = Task { try await coord.sync(albumID: "a1") }
        try await Task.sleep(nanoseconds: 15_000_000)   // let `first` enter the slow fetch
        try await coord.sync(albumID: "a1")             // coalesced — must wait, not return early

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
                                    cache: CloudKitBlobCache.shared, indexStore: self.makeIndexStore())
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
                                            indexStore: index, bus: FileOperationBus())

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "u1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1,
                                         encryptedFileURL: URL(fileURLWithPath: "/tmp/x.blob"),
                                         encryptedThumbURL: URL(fileURLWithPath: "/tmp/x.thumb"))
        _ = try await coord.upload(upload, progress: { _ in })

        // The upload warmed the store cache. Delete the on-disk file underneath: a
        // path that re-read disk every time would now surface an empty index, but
        // the read-through cache must still serve the uploaded entry.
        let warm = await index.current()
        XCTAssertEqual(warm?.entries.map(\.id), ["u1"])
        try FileManager.default.removeItem(at: url)
        let afterDelete = await index.current()
        XCTAssertEqual(afterDelete?.entries.map(\.id), ["u1"],
                       "the cloud read path must serve from the warm cache, not re-decrypt the file each time")
    }

    // Reference holder for Combine sink captures.
    private final class CapturedIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ id: String) { lock.lock(); storage.append(id); lock.unlock() }
        func append(contentsOf ids: [String]) { lock.lock(); storage.append(contentsOf: ids); lock.unlock() }
    }
}
