//
//  IndexCacheReloadTests.swift
//  EncameraCoreTests
//
//  Regression coverage for Bug #16 (Index cache ignores disk): when a
//  separate writer (e.g. the startup migration) updates the on-disk
//  index file, an `InteractableMediaDiskAccess` that already has a warm
//  in-memory cache must notice the newer mtime and reload from disk.
//  Otherwise the gallery keeps paging from a stale snapshot until the
//  album is re-opened.
//

import XCTest
@testable import EncameraCore

final class IndexCacheReloadTests: XCTestCase {

    private func makeTempIndexURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexCacheReloadTests")
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

    /// Stamp the file's mtime explicitly so the test's "newer than warm
    /// cache" condition doesn't depend on filesystem-clock granularity.
    private func setModificationDate(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    /// Once the actor has a warm cache, an external write that lands a
    /// newer mtime on the index file must trigger a reload on the next
    /// access. Pre-fix the in-memory cache was served indefinitely, so a
    /// gallery open during migration would keep showing the partial index.
    func testCachedIndexReloadsWhenDiskIsNewer() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let original = [makeEntry(id: "a"), makeEntry(id: "b")]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: original))
        // Backdate the warm copy so we can rewrite with a strictly-newer
        // mtime later, independent of filesystem-time granularity.
        let oldMtime = Date(timeIntervalSinceNow: -120)
        try setModificationDate(oldMtime, on: indexURL)

        let access = InteractableMediaDiskAccess()
        await access._testSetIndexStore(MediaIndexStore(keyBytes: key, indexURL: indexURL))

        // Warm: the load picks up the original two entries and records the
        // old mtime as the cache timestamp.
        _ = await access._testLoadAndReadCacheTimestamp()
        let warm = await access._testReadCachedIndex()
        XCTAssertEqual(warm?.entries.count, 2)

        // External writer (a second store, mimicking the migration actor)
        // replaces the file with a three-entry index and bumps the mtime.
        let replacement = original + [makeEntry(id: "c")]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: replacement))
        let newMtime = Date()
        try setModificationDate(newMtime, on: indexURL)

        // Now access the index again. The mtime is strictly newer than the
        // warm cache's timestamp, so `cachedOrLoadedIndex` must reload.
        let reloadedTimestamp = await access._testLoadAndReadCacheTimestamp()
        let reloaded = await access._testReadCachedIndex()

        XCTAssertEqual(
            reloaded?.entries.count, 3,
            "Pre-fix regression: cachedOrLoadedIndex served stale in-memory state "
            + "even though the on-disk index file was rewritten with newer mtime."
        )
        XCTAssertTrue(
            reloaded?.entries.contains(where: { $0.id == "c" }) ?? false,
            "Reloaded index is missing the entry the external writer added."
        )
        // The cache timestamp should also have advanced to the new mtime.
        guard let recorded = reloadedTimestamp else {
            return XCTFail("cacheTimestamp was nil after reload")
        }
        XCTAssertLessThan(
            abs(recorded.timeIntervalSince(newMtime)), 1.0,
            "cacheTimestamp must track the on-disk mtime; otherwise the next "
            + "external write isn't detected either."
        )
    }

    /// The reload path must NOT fire when nothing on disk has changed.
    /// A spurious reload every access would defeat the warm-cache
    /// performance work that motivated the index.
    func testCachedIndexDoesNotReloadWhenDiskIsUnchanged() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        let entries = [makeEntry(id: "x"), makeEntry(id: "y")]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: entries))

        let access = InteractableMediaDiskAccess()
        await access._testSetIndexStore(MediaIndexStore(keyBytes: key, indexURL: indexURL))

        let firstTimestamp = await access._testLoadAndReadCacheTimestamp()
        let secondTimestamp = await access._testLoadAndReadCacheTimestamp()
        XCTAssertEqual(
            firstTimestamp, secondTimestamp,
            "cacheTimestamp must be stable across reads when the file has not been modified."
        )
    }
}
