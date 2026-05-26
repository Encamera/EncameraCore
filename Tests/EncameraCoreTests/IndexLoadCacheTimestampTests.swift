//
//  IndexLoadCacheTimestampTests.swift
//  EncameraCoreTests
//
//  Regression coverage for Bug #13: when the on-disk index is loaded for
//  the first time, `cacheTimestamp` must be set to the index file's
//  modification date — not `Date()`. Otherwise any in-place file edits
//  that happened between the index save and the load are silently
//  skipped by `reconcileIndex`, leaving stale sort/filter keys in the
//  paginated gallery.
//

import XCTest
@testable import EncameraCore

final class IndexLoadCacheTimestampTests: XCTestCase {

    private func makeTempIndexURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexLoadCacheTimestampTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.encindex")
    }

    private func randomKey() -> [UInt8] {
        (0..<32).map { _ in UInt8.random(in: 0...255) }
    }

    /// Loading the on-disk index must take its modification date as the
    /// cache timestamp, not the wall-clock moment of the load. A test
    /// builds an index file, backdates it to an hour ago, then loads it
    /// and asserts `cacheTimestamp` equals the backdated mtime.
    func testCacheTimestampMatchesIndexFileModificationDate() async throws {
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }

        // Save a real index.
        let entries: [MediaIndexEntry] = [
            MediaIndexEntry(
                id: UUID().uuidString,
                hasPhotoComponent: true,
                hasVideoComponent: false,
                dateEncrypted: Date(timeIntervalSinceReferenceDate: 700_000_000),
                dateTaken: nil,
                subtypeRawValue: MediaFilterOptions.stillImage.rawValue
            )
        ]
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL)
            .save(MediaIndex(entries: entries))

        // Backdate the index file by an hour so we can tell it apart from
        // `Date()` at load time.
        let backdated = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes(
            [.modificationDate: backdated],
            ofItemAtPath: indexURL.path
        )

        // Load via `cachedOrLoadedIndex` (the path under test) and read
        // the cache timestamp that the actor recorded.
        let access = InteractableMediaDiskAccess()
        await access._testSetIndexStore(MediaIndexStore(keyBytes: key, indexURL: indexURL))
        let recorded = await access._testLoadAndReadCacheTimestamp()

        guard let recorded else {
            return XCTFail("cacheTimestamp was nil — load path didn't run")
        }
        // Allow a tiny epsilon because `setAttributes` truncates to
        // millisecond/second granularity on some filesystems.
        let drift = abs(recorded.timeIntervalSince(backdated))
        XCTAssertLessThan(
            drift, 1.0,
            "cacheTimestamp should match the index file's mtime (\(backdated)), "
            + "got \(recorded). Pre-fix the loader used Date() and missed in-place "
            + "edits that landed between save and load."
        )

        // Sanity: the recorded timestamp is clearly in the past, not "now".
        XCTAssertLessThan(
            recorded.timeIntervalSinceNow, -60,
            "cacheTimestamp is suspiciously recent — the fix probably regressed "
            + "to Date()."
        )
    }
}
