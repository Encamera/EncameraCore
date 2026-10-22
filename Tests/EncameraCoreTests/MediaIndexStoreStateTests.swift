//
//  MediaIndexStoreStateTests.swift
//  EncameraCoreTests
//
//  `MediaIndexStore` is the single stateful owner of a per-album media index —
//  it holds the warm in-memory cache and the load→mutate→save→cache (with
//  rollback) envelope that both backends drive through. These tests pin that
//  behavior directly on the store, with no backend and no `_test…` indirection.
//

import XCTest
@testable import EncameraCore

final class MediaIndexStoreStateTests: XCTestCase {

    private func makeTempIndexURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaIndexStoreStateTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.encindex")
    }

    private func randomKey() -> [UInt8] {
        (0..<32).map { _ in UInt8.random(in: 0...255) }
    }

    private func makeEntry(id: String = UUID().uuidString) -> MediaIndexEntry {
        MediaIndexEntry(
            id: id,
            hasPhotoComponent: true,
            hasVideoComponent: false,
            dateEncrypted: Date(timeIntervalSinceReferenceDate: 700_000_000),
            dateTaken: nil,
            subtypeRawValue: MediaFilterOptions.stillImage.rawValue
        )
    }

    private func setModificationDate(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - current()

    func testCurrentReadsThroughAndCachesOnFirstAccess() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let entries = [makeEntry(id: "a"), makeEntry(id: "b")]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL).save(MediaIndex(entries: entries))

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        let preCache = await store._testCachedIndex()
        XCTAssertNil(preCache, "the cache is empty before the first access")

        let loaded = await store.current()
        XCTAssertEqual(loaded?.entries.count, 2)

        try FileManager.default.removeItem(at: indexURL)
        let warm = await store.current()
        XCTAssertEqual(warm?.entries.count, 2, "current() must serve the warm cache, not re-read disk every time")
    }

    func testCurrentReloadsWhenDiskFileIsNewer() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let original = [makeEntry(id: "a"), makeEntry(id: "b")]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL).save(MediaIndex(entries: original))
        try setModificationDate(Date(timeIntervalSinceNow: -120), on: indexURL)

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        let warm = await store.current()
        XCTAssertEqual(warm?.entries.count, 2)

        let replacement = original + [makeEntry(id: "c")]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL).save(MediaIndex(entries: replacement))
        let newMtime = Date()
        try setModificationDate(newMtime, on: indexURL)

        let reloaded = await store.current()
        XCTAssertEqual(reloaded?.entries.count, 3, "a newer on-disk file must trigger a reload")
        XCTAssertTrue(reloaded?.entries.contains(where: { $0.id == "c" }) ?? false)

        let recorded = await store._testCacheTimestamp()
        XCTAssertEqual(abs((recorded ?? .distantPast).timeIntervalSince(newMtime)), 0, accuracy: 1.0,
                       "the cache timestamp must advance to the reloaded file's mtime")
    }

    func testCurrentDoesNotReloadWhenDiskUnchanged() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: [makeEntry(id: "x"), makeEntry(id: "y")]))

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        _ = await store.current()
        let firstTimestamp = await store._testCacheTimestamp()
        _ = await store.current()
        let secondTimestamp = await store._testCacheTimestamp()
        XCTAssertEqual(firstTimestamp, secondTimestamp,
                       "the cache timestamp must be stable across reads when the file is unchanged")
    }

    func testCacheTimestampMatchesFileModificationDate() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: [makeEntry()]))
        let backdated = Date().addingTimeInterval(-3600)
        try setModificationDate(backdated, on: indexURL)

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        _ = await store.current()
        let recorded = await store._testCacheTimestamp()
        guard let recorded else { return XCTFail("cacheTimestamp was nil — load path didn't run") }
        XCTAssertEqual(recorded.timeIntervalSince(backdated), 0, accuracy: 1.0,
                       "cacheTimestamp must match the index file's mtime, not Date() at load time")
        XCTAssertLessThan(recorded.timeIntervalSinceNow, -60, "the timestamp must be the backdated mtime, not 'now'")
    }

    // MARK: - apply()

    func testApplySavesOnceAndUpdatesCache() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        let entry = makeEntry(id: "a")
        let changed = try await store.apply { $0.upsert(entry) }
        XCTAssertTrue(changed)

        let cached = await store._testCachedIndex()
        XCTAssertEqual(cached?.entries.map(\.id), ["a"])
        let fresh = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        let persisted = await fresh.load()
        XCTAssertEqual(persisted?.entries.map(\.id), ["a"])
    }

    func testApplyRollsBackCacheOnSaveFailure() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let entryA = makeEntry()
        let entryB = makeEntry()
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: [entryA, entryB]))

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        let warm = await store.current()
        XCTAssertEqual(warm?.entries.count, 2)

        // `Data.write(to:)` refuses to overwrite a directory, so replacing the index
        // file with a directory forces every save to throw.
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)

        do {
            _ = try await store.remove(ids: [entryA.id])
            XCTFail("the save must throw when the file path is blocked")
        } catch {
            // expected
        }

        let afterFailure = await store._testCachedIndex()
        XCTAssertEqual(afterFailure?.entries.count, 2,
                       "a failed save must leave the cache at its pre-mutation state (Bug #14)")
        XCTAssertTrue(afterFailure?.entries.contains(where: { $0.id == entryA.id }) ?? false,
                      "the supposedly-removed entry must still be present after the failed save")
    }

    func testRemoveUpdatesCacheOnSuccess() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let entryA = makeEntry()
        let entryB = makeEntry()
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: [entryA, entryB]))

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        _ = await store.current()
        let entryRemoved = try await store.remove(ids: [entryA.id])
        XCTAssertTrue(entryRemoved)

        let cached = await store._testCachedIndex()
        XCTAssertEqual(cached?.entries.map(\.id), [entryB.id], "a successful remove must advance the cache")
    }

    func testApplyNoOpDoesNotRewriteFile() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let entry = makeEntry(id: "a")
        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        _ = try await store.upsert([entry])
        let mtimeBefore = store.fileModificationDate()
        XCTAssertNotNil(mtimeBefore)

        try setModificationDate(Date(timeIntervalSinceNow: -120), on: indexURL)
        let backdated = store.fileModificationDate()

        let changed = try await store.upsert([entry])
        XCTAssertFalse(changed, "an idempotent upsert reports no change")
        XCTAssertEqual(store.fileModificationDate(), backdated, "a no-op mutation must not rewrite the file")

        let removed = try await store.removeComponent(recordName: "ghost#0")
        XCTAssertTrue(removed, "a missing record counts as already removed")
        XCTAssertEqual(store.fileModificationDate(), backdated, "removing a missing record must not rewrite the file")
    }

    // MARK: - replace()

    func testReplaceWritesWholeIndexAndUpdatesCache() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        _ = try await store.upsert([makeEntry(id: "old1"), makeEntry(id: "old2")])

        let replacement = [makeEntry(id: "new")]
        try await store.replace(with: replacement)

        let cached = await store._testCachedIndex()
        XCTAssertEqual(cached?.entries.map(\.id), ["new"], "replace swaps the whole index in the cache")
        let fresh = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        let persisted = await fresh.load()
        XCTAssertEqual(persisted?.entries.map(\.id), ["new"], "replace persists the whole index")
    }

    func testGenerationGuardedReplaceRefusesAfterInterleavedMutation() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        _ = try await store.upsert([makeEntry(id: "existing")])

        let generation = await store.currentGeneration()
        _ = try await store.upsert([makeEntry(id: "interleaved")])

        let wrote = try await store.replace(with: [makeEntry(id: "stale")], ifGenerationIs: generation)
        XCTAssertFalse(wrote, "a generation mismatch must refuse the stale replace")
        let current = await store.current()
        XCTAssertEqual(current?.entries.map(\.id), ["existing", "interleaved"], "the interleaved write must survive")

        let freshGeneration = await store.currentGeneration()
        let wroteFresh = try await store.replace(with: [makeEntry(id: "reconciled")], ifGenerationIs: freshGeneration)
        XCTAssertTrue(wroteFresh, "a matching generation must write")
        let after = await store.current()
        XCTAssertEqual(after?.entries.map(\.id), ["reconciled"])
    }

    // MARK: - One store per album

    private func makeCloudKitAlbum() -> Album {
        Album(name: "one-store-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
              key: PrivateKey(keyBytes: randomKey(), creationDate: Date()), albumID: UUID().uuidString)
    }

    /// The app builds a new `AlbumManager` each time the key becomes available;
    /// every one of them must hand out the same store for an album.
    func testAlbumManagerReturnsOneStorePerAlbum() {
        let album = makeCloudKitAlbum()
        let first = AlbumManager(keyManager: DemoKeyManager())
        let second = AlbumManager(keyManager: DemoKeyManager())

        XCTAssertTrue(first.mediaIndexStore(for: album) === second.mediaIndexStore(for: album))
        XCTAssertTrue(first.sizeSidecar(for: album) === second.sizeSidecar(for: album))
        XCTAssertTrue(first.mediaIndexStore(forAlbumID: album.albumID!) === first.mediaIndexStore(for: album),
                      "a lookup by CloudKit album id finds the store already handed out")
        let other = makeCloudKitAlbum()
        XCTAssertFalse(first.mediaIndexStore(for: album) === first.mediaIndexStore(for: other))
        AlbumStoreRegistry.shared.drop(albumWithID: album.id)
        AlbumStoreRegistry.shared.drop(albumWithID: other.id)
    }

    /// Two writers that each built their own store would both load the same file and
    /// the later save would drop the earlier write. Through the one store, every
    /// upsert lands.
    func testTwoCallersDoNotLoseConcurrentUpserts() async throws {
        let album = makeCloudKitAlbum()
        defer {
            try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
            AlbumStoreRegistry.shared.drop(albumWithID: album.id)
        }
        let first = AlbumManager(keyManager: DemoKeyManager())
        let second = AlbumManager(keyManager: DemoKeyManager())
        let ids = (0..<40).map { "item-\($0)" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                let manager = index.isMultiple(of: 2) ? first : second
                let store = manager.mediaIndexStore(for: album)
                let entry = makeEntry(id: id)
                group.addTask { try await store.upsert([entry]) }
            }
            try await group.waitForAll()
        }

        let onDisk = MediaIndexStore.storedEntries(for: album).map(\.id)
        XCTAssertEqual(Set(onDisk), Set(ids), "no upsert may be lost to another writer's save")
    }

    /// A deleted album's store is forgotten, so a later album that reuses nothing of
    /// it — or a store served from memory after its file is gone — cannot leak into
    /// the next request.
    func testDeletedAlbumDropsItsStore() throws {
        let previousMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in MockCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = previousMakeStore }
        let manager = AlbumManager(keyManager: DemoKeyManager())
        let album = makeCloudKitAlbum()
        try CloudKitAlbumMarker(album: album, isHidden: false).write(albumID: album.albumID!)
        defer { try? CloudKitAlbumMarker.remove(albumID: album.albumID!) }
        let before = manager.mediaIndexStore(for: album)
        let sidecarBefore = manager.sizeSidecar(for: album)

        try manager.delete(album: album)

        XCTAssertNil(AlbumStoreRegistry.shared.existingIndexStore(forCloudKitAlbumID: album.albumID!),
                     "delete must drop the album's index store")
        XCTAssertNil(AlbumStoreRegistry.shared.existingSizeSidecar(forCloudKitAlbumID: album.albumID!))
        XCTAssertFalse(manager.mediaIndexStore(for: album) === before)
        XCTAssertFalse(manager.sizeSidecar(for: album) === sidecarBefore)
        AlbumStoreRegistry.shared.drop(albumWithID: album.id)
    }

    /// The store outlives any one index file, so a reload of a removed file must not
    /// go on serving the copy in memory.
    func testReloadOfRemovedIndexDropsTheCachedCopy() async throws {
        let indexURL = try makeTempIndexURL()
        let store = MediaIndexStore(keyBytes: randomKey(), indexURL: indexURL)
        try await store.upsert([makeEntry(id: "a")])
        try FileManager.default.removeItem(at: indexURL)

        let reloaded = await store.reloadFromDisk()
        let current = await store.current()

        XCTAssertNil(reloaded)
        XCTAssertNil(current, "a removed index must be rebuilt, not served from memory")
    }
}
