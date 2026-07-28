//
//  CloudKitBlobCacheTests.swift
//  EncameraCoreTests
//
//  The byte-cap eviction must never invalidate the URL `store` is about to
//  return: `ensureBlobLocal` deletes its download temp and hands that URL to
//  callers (`exportCiphertext`, the viewer), so a self-evicted entry turns every
//  oversized blob into an unopenable file and permanently blocks the
//  CloudKit -> local move for its album.
//

import XCTest
@testable import EncameraCore

final class CloudKitBlobCacheTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeCache(maxBytes: Int64) -> CloudKitBlobCache {
        CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache", isDirectory: true),
                          maxBytes: maxBytes)
    }

    private func sourceFile(bytes: Int) throws -> URL {
        let url = tempRoot.appendingPathComponent("source-\(UUID().uuidString)")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    func testStoreOfBlobLargerThanCapDoesNotEvictItself() async throws {
        // A single blob bigger than the whole cap (a few minutes of 4K video vs
        // the 500 MB default) can never fit — but the entry just stored is the one
        // the caller is being handed a URL to, so it must survive this pass.
        let cache = makeCache(maxBytes: 100)
        let url = try await cache.store(recordName: "big",
                                        changeTag: nil,
                                        albumID: "album",
                                        from: sourceFile(bytes: 150))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "store must never return a URL to a file its own eviction pass deleted")
        let cached = await cache.cachedURL(recordName: "big", changeTag: nil)
        XCTAssertNotNil(cached, "the just-stored entry must still be indexed")
    }

    func testOversizedStoreStillEvictsOlderEntries() async throws {
        // Protecting the just-stored entry must not turn the cap off: everything
        // ELSE is still evicted LRU-first to get as close to the cap as possible.
        let cache = makeCache(maxBytes: 100)
        _ = try await cache.store(recordName: "old",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 60))
        _ = try await cache.store(recordName: "big",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 150))

        let old = await cache.cachedURL(recordName: "old", changeTag: nil)
        XCTAssertNil(old, "older entries are still evicted to make room")
        let big = await cache.cachedURL(recordName: "big", changeTag: nil)
        XCTAssertNotNil(big)
    }

    func testStoreWithinCapEvictsLeastRecentlyUsedFirst() async throws {
        // The pre-existing LRU contract, pinned so the fix cannot regress it.
        let cache = makeCache(maxBytes: 100)
        _ = try await cache.store(recordName: "first",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 60))
        // Touch "first" so "second" becomes the LRU entry.
        _ = try await cache.store(recordName: "second",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 30))
        _ = await cache.cachedURL(recordName: "first", changeTag: nil)
        _ = try await cache.store(recordName: "third",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 30))

        let second = await cache.cachedURL(recordName: "second", changeTag: nil)
        XCTAssertNil(second, "the least-recently-used entry goes first")
        let first = await cache.cachedURL(recordName: "first", changeTag: nil)
        XCTAssertNotNil(first)
        let third = await cache.cachedURL(recordName: "third", changeTag: nil)
        XCTAssertNotNil(third)
    }
}
