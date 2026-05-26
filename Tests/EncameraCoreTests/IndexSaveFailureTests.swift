//
//  IndexSaveFailureTests.swift
//  EncameraCoreTests
//
//  Regression coverage for Bug #14: when `MediaIndexStore.save` throws,
//  the in-memory `cachedIndex` must not advance past the on-disk state.
//  Pre-fix `try?` silently swallowed the error and left an inconsistency
//  between memory and disk that would surface as data loss after a
//  relaunch fell back to the on-disk index.
//

import XCTest
@testable import EncameraCore

final class IndexSaveFailureTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexSaveFailureTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    /// When `removeFromIndex` tries to save and disk persistence fails,
    /// the in-memory `cachedIndex` must remain at the pre-removal state so
    /// memory and disk stay in sync. Otherwise a relaunch loads the older
    /// disk state and the removal silently reappears.
    func testRemoveFromIndexRollsBackCacheOnSaveFailure() async throws {
        let key = randomKey()
        let dir = try makeTempDir()
        // Use two separate paths for warming vs. failing-save so the load
        // sees a real file but the save sees a directory in the file's place.
        let warmIndexURL = dir.appendingPathComponent("warm.encindex")
        let blockedIndexURL = dir.appendingPathComponent("blocked.encindex")
        defer { try? FileManager.default.removeItem(at: dir) }

        let entryA = makeEntry()
        let entryB = makeEntry()

        // Persist a real index with two entries so the load path warms the
        // cache with a known starting state.
        try await MediaIndexStore(keyBytes: key, indexURL: warmIndexURL)
            .save(MediaIndex(entries: [entryA, entryB]))

        // Warm via the loadable store...
        let access = InteractableMediaDiskAccess()
        await access._testSetIndexStore(MediaIndexStore(keyBytes: key, indexURL: warmIndexURL))
        let warmTimestamp = await access._testLoadAndReadCacheTimestamp()
        XCTAssertNotNil(warmTimestamp)
        let warm = await access._testReadCachedIndex()
        XCTAssertEqual(warm?.entries.count, 2)

        // ...then swap to a store whose save must fail. `Data.write(to:)`
        // refuses to overwrite a directory, so creating a directory at the
        // index file's path forces every save to throw.
        try FileManager.default.createDirectory(at: blockedIndexURL, withIntermediateDirectories: true)
        await access._testSetIndexStore(MediaIndexStore(keyBytes: key, indexURL: blockedIndexURL))

        await access.removeFromIndex(ids: [entryA.id])

        // Post-fix: the save failed, so the cached index is still at two
        // entries. Pre-fix the cache would have advanced to one entry while
        // disk is gone — on relaunch the album reappears with both items.
        let afterFailedRemove = await access._testReadCachedIndex()
        XCTAssertEqual(
            afterFailedRemove?.entries.count, 2,
            "Pre-fix regression: cachedIndex advanced past the failed save. "
            + "removeFromIndex must persist successfully before mutating the cache."
        )
        XCTAssertTrue(
            afterFailedRemove?.entries.contains(where: { $0.id == entryA.id }) ?? false,
            "Pre-fix regression: the supposedly-removed entry is gone from the "
            + "cache even though the disk save failed."
        )
    }

    /// Sanity: when the save succeeds, the cache DOES advance. This pins
    /// the happy path so a future fix doesn't accidentally roll back on
    /// success too.
    func testRemoveFromIndexUpdatesCacheOnSaveSuccess() async throws {
        let key = randomKey()
        let dir = try makeTempDir()
        let indexURL = dir.appendingPathComponent("index.encindex")
        defer { try? FileManager.default.removeItem(at: dir) }

        let entryA = makeEntry()
        let entryB = makeEntry()
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: [entryA, entryB]))

        let access = InteractableMediaDiskAccess()
        await access._testSetIndexStore(MediaIndexStore(keyBytes: key, indexURL: indexURL))
        _ = await access._testLoadAndReadCacheTimestamp()

        await access.removeFromIndex(ids: [entryA.id])

        let updated = await access._testReadCachedIndex()
        XCTAssertEqual(updated?.entries.count, 1)
        XCTAssertEqual(updated?.entries.first?.id, entryB.id)
    }
}
