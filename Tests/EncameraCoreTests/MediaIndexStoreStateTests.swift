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

        // The first access warms the cache; deleting the file underneath must not
        // empty a subsequent read.
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

        // An external writer rewrites the file with a newer mtime.
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

        // Cache reflects the mutation...
        let cached = await store._testCachedIndex()
        XCTAssertEqual(cached?.entries.map(\.id), ["a"])
        // ...and it was persisted (a fresh store reads it back).
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

        // Backdate so any rewrite would be detectable as a strictly-newer mtime.
        try setModificationDate(Date(timeIntervalSinceNow: -120), on: indexURL)
        let backdated = store.fileModificationDate()

        // Re-upserting the identical entry changes nothing — the file must not be rewritten.
        let changed = try await store.upsert([entry])
        XCTAssertFalse(changed, "an idempotent upsert reports no change")
        XCTAssertEqual(store.fileModificationDate(), backdated, "a no-op mutation must not rewrite the file")

        // removeComponent for a record name with no matching entry is also a no-op.
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

        // A reconcile captures the generation, scans (suspending), and meanwhile
        // an incremental save lands.
        let generation = await store.currentGeneration()
        _ = try await store.upsert([makeEntry(id: "interleaved")])

        // The stale snapshot must be refused, leaving the interleaved write intact.
        let wrote = try await store.replace(with: [makeEntry(id: "stale")], ifGenerationIs: generation)
        XCTAssertFalse(wrote, "a generation mismatch must refuse the stale replace")
        let current = await store.current()
        XCTAssertEqual(current?.entries.map(\.id), ["existing", "interleaved"], "the interleaved write must survive")

        // With a fresh generation the replace goes through.
        let freshGeneration = await store.currentGeneration()
        let wroteFresh = try await store.replace(with: [makeEntry(id: "reconciled")], ifGenerationIs: freshGeneration)
        XCTAssertTrue(wroteFresh, "a matching generation must write")
        let after = await store.current()
        XCTAssertEqual(after?.entries.map(\.id), ["reconciled"])
    }
}
