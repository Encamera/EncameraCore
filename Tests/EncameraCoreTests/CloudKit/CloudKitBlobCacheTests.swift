//
//  CloudKitBlobCacheTests.swift
//  EncameraCoreTests
//
//  The byte-cap eviction must never invalidate the URL `store` is about to
//  return: `ensureBlobLocal` deletes its download temp and hands that URL to
//  callers (the move back to local storage, the viewer), so a self-evicted entry turns every
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
        let cache = makeCache(maxBytes: 100)
        _ = try await cache.store(recordName: "first",
                                  changeTag: nil,
                                  albumID: "album",
                                  from: sourceFile(bytes: 60))
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

    // MARK: - Read-only size lookup

    /// A size read is what the info screen does, and it must not reorder the LRU:
    /// the entry it reported on stays exactly as recently used as it was, so the
    /// cap still evicts what the user actually stopped using.
    func testCachedSizeDoesNotMakeTheEntryMostRecentlyUsed() async throws {
        let cache = makeCache(maxBytes: 200)
        let hot = try await cache.store(recordName: "hot", changeTag: nil, albumID: "album",
                                        from: sourceFile(bytes: 40))
        let cold = try await cache.store(recordName: "cold", changeTag: nil, albumID: "album",
                                         from: sourceFile(bytes: 40))

        for _ in 0..<5 {
            let size = await cache.cachedSize(recordName: "hot", changeTag: nil)
            XCTAssertEqual(size, 40)
        }

        _ = try await cache.store(recordName: "fresh", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 150))

        XCTAssertFalse(FileManager.default.fileExists(atPath: hot.path),
                       "A size read must not protect an entry from LRU eviction")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cold.path),
                      "The genuinely more recently used entry must survive")
    }

    func testCachedSizeReportsNothingForAStaleTagOrAMissingFile() async throws {
        let cache = makeCache(maxBytes: 10_000)
        let url = try await cache.store(recordName: "m1", changeTag: "t1", albumID: "album",
                                        from: sourceFile(bytes: 40))

        let matching = await cache.cachedSize(recordName: "m1", changeTag: "t1")
        XCTAssertEqual(matching, 40)
        let stale = await cache.cachedSize(recordName: "m1", changeTag: "t2")
        XCTAssertNil(stale, "A newer server tag invalidates the cached copy")
        let untagged = await cache.cachedSize(recordName: "m1", changeTag: nil)
        XCTAssertEqual(untagged, 40, "No expectation trusts the persisted entry")
        let absent = await cache.cachedSize(recordName: "nope", changeTag: nil)
        XCTAssertNil(absent)

        try FileManager.default.removeItem(at: url)

        let gone = await cache.cachedSize(recordName: "m1", changeTag: "t1")
        XCTAssertNil(gone, "Bytes that are not on disk must not be reported as a local copy")
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 40, "And the read stays read-only: the index is not rewritten")
    }

    // MARK: - Disk truth

    /// The cache directory as an outside observer sees it, so a test never grades
    /// the cache against its own bookkeeping.
    private func measureCacheDirectory() throws -> (logical: Int64, files: Int) {
        let root = tempRoot.appendingPathComponent("cache", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var count = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, url.lastPathComponent != ".cacheindex.json" else { continue }
            bytes += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    /// Writes a blob into an album folder without going through the actor — the
    /// on-disk shape a failed eviction leaves behind.
    @discardableResult
    private func plantOrphan(albumID: String, recordName: String, bytes: Int) throws -> URL {
        let folder = tempRoot.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(CloudKitBlobCache.albumFolderName(albumID), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(recordName)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        return url
    }

    /// The exact gap that makes a storage screen lie: bytes on disk that the
    /// in-memory index does not know about.
    func testDiskBytesCountsFilesMissingFromTheIndex() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "tracked", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album", recordName: "orphan", bytes: 60)

        let tracked = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(tracked, 40, "The in-memory figure only knows what it stored")
        XCTAssertEqual(onDisk, 100, "Disk truth includes the untracked file")
        XCTAssertEqual(onDisk, try measureCacheDirectory().logical,
                       "And matches an independent measurement of the directory")
    }

    /// What the storage screen attributes per album: every file, index entry or
    /// not, named by its folder and record name.
    func testAllocatedFilesListsEveryFileByAlbumFolder() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "x#0", changeTag: nil, albumID: "album-a",
                                  from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album-b", recordName: "y#1", bytes: 60)
        try plantOrphan(albumID: "album-b", recordName: "y#1#c0", bytes: 30)

        let files = await cache.allocatedFiles()
        let allocatedTotal = await cache.allocatedDiskBytes()

        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.recordName, $0) })
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(byName["x#0"]?.albumFolder, CloudKitBlobCache.albumFolderName("album-a"))
        XCTAssertEqual(byName["y#1"]?.albumFolder, CloudKitBlobCache.albumFolderName("album-b"))
        XCTAssertEqual(byName["y#1#c0"]?.albumFolder, CloudKitBlobCache.albumFolderName("album-b"))
        XCTAssertEqual(files.reduce(0) { $0 + $1.allocatedBytes }, allocatedTotal)
        XCTAssertFalse(files.contains { $0.recordName == ".cacheindex.json" })
    }

    func testReconcileReportsOrphanedFiles() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "tracked", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album", recordName: "orphan", bytes: 60)

        let result = await cache.reconcile()
        XCTAssertEqual(result.orphanedFiles, 1)
        XCTAssertEqual(result.orphanedBytes, 60)

        let tracked = await cache.totalBytes()
        XCTAssertEqual(tracked, 100, "An adopted orphan counts against the cap from now on")
        let again = await cache.reconcile()
        XCTAssertEqual(again.orphanedFiles, 0, "Adoption is idempotent")
    }

    /// After a failed eviction the file is still there, so its bytes must still
    /// count — otherwise the cache reports less than it occupies.
    func testFailedEvictionKeepsTheEntryAndItsBytes() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "stuck", changeTag: nil, albumID: "album",
                                  from: sourceFile(bytes: 80))
        let albumDir = tempRoot.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(CloudKitBlobCache.albumFolderName("album"), isDirectory: true)
        // A read-only parent directory makes `removeItem` fail while the file lives on.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: albumDir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: albumDir.path)
        }

        await cache.evict(recordName: "stuck")

        let total = await cache.totalBytes()
        XCTAssertEqual(total, 80, "A file that survived eviction keeps counting")
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(onDisk, 80)
    }

    // MARK: - Batched eviction

    /// Evicting the chunks of one video is thousands of records; the sidecar is
    /// re-encoded and rewritten once, not once per record.
    func testBatchEvictWritesTheIndexOnce() async throws {
        let cache = makeCache(maxBytes: 10_000)
        var names: [String] = []
        for chunk in 0..<5 {
            let name = "vid#1--c\(chunk)"
            names.append(name)
            _ = try await cache.store(recordName: name, changeTag: nil, albumID: "album",
                                      from: sourceFile(bytes: 40))
        }
        let before = await cache.indexPersistCount

        await cache.evict(recordNames: names)

        let writes = await cache.indexPersistCount - before
        XCTAssertEqual(writes, 1, "One batch, one index write — got \(writes)")
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 0)
        XCTAssertEqual(try measureCacheDirectory().files, 0, "Every chunk file is gone")
    }

    /// A removal that fails must not abandon the rest of the batch, and the index
    /// must still be written — otherwise it goes on describing files that are gone.
    func testBatchEvictRemovesEveryFileWhenOneRemovalFails() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "stuck", changeTag: nil, albumID: "locked",
                                  from: sourceFile(bytes: 80))
        let removable = try await [
            cache.store(recordName: "c0", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40)),
            cache.store(recordName: "c1", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))
        ]
        let lockedDir = tempRoot.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(CloudKitBlobCache.albumFolderName("locked"), isDirectory: true)
        // A read-only parent directory makes `removeItem` fail while the file lives on.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDir.path)
        }
        let before = await cache.indexPersistCount

        await cache.evict(recordNames: ["stuck", "c0", "c1"])

        for url in removable {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "A failed removal must not stop the ones after it: \(url.lastPathComponent) survived")
        }
        let writes = await cache.indexPersistCount - before
        XCTAssertEqual(writes, 1, "A partial eviction must still write the index once — got \(writes)")
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 80, "The file that survived eviction keeps counting")
        XCTAssertEqual(try measureCacheDirectory().files, 1)
    }

    func testDiskBytesMatchesTotalBytesWhenTheCacheIsConsistent() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))
        _ = try await cache.store(recordName: "b", changeTag: nil, albumID: "other", from: sourceFile(bytes: 70))

        let total = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(total, 110)
        XCTAssertEqual(onDisk, total, "The two figures may only differ by orphans")
    }

    /// Allocated size is block-rounded, so it is never smaller than the logical
    /// size — which is why the storage screen reports it rather than the other one.
    func testAllocatedDiskBytesIsNeverLessThanLogicalBytes() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))

        let logical = await cache.diskBytes()
        let allocated = await cache.allocatedDiskBytes()
        XCTAssertGreaterThanOrEqual(allocated, logical)
    }

    func testClearAllZeroesBothFigures() async throws {
        let cache = makeCache(maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))
        try plantOrphan(albumID: "album", recordName: "orphan", bytes: 60)

        try await cache.clearAll()

        let total = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(total, 0)
        XCTAssertEqual(onDisk, 0, "Including the files the index never knew about")
        XCTAssertEqual(try measureCacheDirectory().files, 0)
    }

    // MARK: - Free up space

    private var cacheRoot: URL { tempRoot.appendingPathComponent("cache", isDirectory: true) }

    private func makeUploadQueue() -> CloudKitUploadQueue {
        CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("uploads", isDirectory: true))
    }

    /// Writes a metadata file at `relativePath` under the cache root.
    @discardableResult
    private func plantMetadata(_ relativePath: String, contents: String = "{}") throws -> URL {
        let url = cacheRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// The cache root also holds per-album sidecars, so freeing space must take the
    /// ciphertext and nothing else.
    func testFreeUpSpaceKeepsSidecarsAndDeletesOnlyBlobs() async throws {
        let cache = makeCache(maxBytes: 10_000)
        let blob = try await cache.store(recordName: "a#0", changeTag: "t", albumID: "album",
                                         from: sourceFile(bytes: 40))
        let chunk = try await cache.store(recordName: "v#1#c0", changeTag: "t", albumID: "album",
                                          from: sourceFile(bytes: 30))
        let orphan = try plantOrphan(albumID: "album", recordName: "orphan#0", bytes: 60)
        let thumbTags = try plantMetadata("\(CloudKitBlobCache.albumFolderName("album"))/.thumbtags.json")

        try await cache.freeUpSpace(pendingUploads: makeUploadQueue())

        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbTags.path), ".thumbtags.json must survive")
        for gone in [blob, chunk, orphan] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "\(gone.lastPathComponent) must be deleted")
        }
        let total = await cache.totalBytes()
        let onDisk = await cache.diskBytes()
        XCTAssertEqual(total, 0)
        XCTAssertEqual(onDisk, 0, "Metadata is not cached media and is not counted as such")
        let cachedA = await cache.cachedURL(recordName: "a#0", changeTag: nil)
        XCTAssertNil(cachedA)

        let reloaded = makeCache(maxBytes: 10_000)
        let reloadedTotal = await reloaded.totalBytes()
        XCTAssertEqual(reloadedTotal, 0, "The persisted index must not list the removed blobs")
        let indexData = try Data(contentsOf: cacheRoot.appendingPathComponent(".cacheindex.json"))
        let entries = try JSONSerialization.jsonObject(with: indexData) as? [String: Any]
        XCTAssertEqual(entries?.count, 0, "The persisted index must not list the removed blobs")
    }

    /// A capture's ciphertext is written into the album folder before the upload
    /// queue takes it, and a record stays pending until CloudKit confirms it. Either
    /// may be the only copy on the device.
    func testFreeUpSpaceNeverDeletesAPendingCapture() async throws {
        let cache = makeCache(maxBytes: 10_000)
        let queue = makeUploadQueue()

        let pendingSource = try sourceFile(bytes: 50)
        try await queue.enqueue(CloudKitMediaUpload(albumID: "album", mediaID: "p",
                                                    mediaType: .photo, createdAt: Date(), sizeBytes: 50,
                                                    encryptedFileURL: pendingSource, encryptedThumbURL: nil,
                                                    recordName: "p#0", keyFingerprint: ""))
        let pendingCached = try await cache.store(recordName: "p#0", changeTag: "t", albumID: "album",
                                                  from: sourceFile(bytes: 50))
        let staged = try plantOrphan(albumID: "album", recordName: "s.\(MediaType.photo.encryptedFileExtension)", bytes: 70)
        let committed = try await cache.store(recordName: "c#0", changeTag: "t", albumID: "album",
                                              from: sourceFile(bytes: 40))

        try await cache.freeUpSpace(pendingUploads: queue)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingCached.path),
                      "A blob whose upload is not committed must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                      "A capture not yet handed to the upload queue must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path), "A committed blob must be freed")
        let stillCached = await cache.cachedURL(recordName: "p#0", changeTag: "t")
        XCTAssertNotNil(stillCached, "The surviving pending blob stays indexed")
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 50)
        let pendingURL = await queue.pendingFileURL(recordName: "p#0")
        XCTAssertNotNil(pendingURL, "The queue's own copy is untouched")
    }

    // MARK: - Relocate

    func testRelocateMovesFileAndRewritesEntry() async throws {
        let cache = makeCache(maxBytes: 10_000)
        let tag = "t1"
        _ = try await cache.store(recordName: "rec1", changeTag: tag, albumID: "album-a",
                                  from: sourceFile(bytes: 80))
        let persistBefore = await cache.indexPersistCount
        let bytesBefore = await cache.totalBytes()

        await cache.relocate(recordName: "rec1", toAlbumID: "album-b")

        // The entry resolves under album-b's folder now.
        let newURL = await cache.cachedURL(recordName: "rec1", changeTag: tag)
        XCTAssertNotNil(newURL)
        let expectedFolder = CloudKitBlobCache.albumFolderName("album-b")
        XCTAssertTrue(newURL!.path.contains(expectedFolder),
                      "The cached file should live under album-b's folder")

        // The old file is gone.
        let oldFolder = CloudKitBlobCache.albumFolderName("album-a")
        let oldPath = tempRoot.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(oldFolder, isDirectory: true)
            .appendingPathComponent("rec1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path),
                       "The file at the old location must be gone")

        // Byte count unchanged; exactly one persist for the relocate.
        let bytesAfter = await cache.totalBytes()
        XCTAssertEqual(bytesAfter, bytesBefore, "totalBytes must be unchanged after a relocate")
        let persistAfter = await cache.indexPersistCount
        XCTAssertEqual(persistAfter - persistBefore, 1,
                       "relocate must persist exactly once")
    }

    func testRelocateUnknownRecordIsNoOp() async throws {
        let cache = makeCache(maxBytes: 10_000)
        let persistBefore = await cache.indexPersistCount

        await cache.relocate(recordName: "nonexistent", toAlbumID: "album-b")

        let persistAfter = await cache.indexPersistCount
        XCTAssertEqual(persistAfter, persistBefore,
                       "A no-op relocate must not persist")
    }

    // MARK: - Album markers

    /// iOS purges `Library/Caches` when storage runs low. A CloudKit album created
    /// offline exists on the device only as its marker, so the purge must not take
    /// the album, its hidden flag, or the link from its queued captures to it.
    func testPurgingBlobCacheKeepsUnpublishedHiddenAlbum() async throws {
        let key = PrivateKey(name: "purge-\(UUID().uuidString.prefix(6))",
                             keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let albumID = UUID().uuidString
        let album = Album(name: "Private-\(UUID().uuidString)", storageOption: .cloudKit,
                          creationDate: Date(), key: key, albumID: albumID)
        try CloudKitAlbumMarker(album: album, isHidden: true, dirty: true).write(albumID: albumID)
        addTeardownBlock { try? CloudKitAlbumMarker.remove(albumID: albumID) }

        let queue = CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("uploads", isDirectory: true))
        let capture = tempRoot.appendingPathComponent("capture.encimage")
        try Data(repeating: 0x42, count: 64).write(to: capture)
        try await queue.enqueue(CloudKitMediaUpload(albumID: albumID, mediaID: "m1", mediaType: .photo,
                                                    createdAt: Date(), sizeBytes: 64,
                                                    encryptedFileURL: capture, encryptedThumbURL: nil,
                                                    recordName: "m1#0"))
        let albumCacheFolder = CloudKitStorageModel(album: album).baseURL
        try FileManager.default.createDirectory(at: albumCacheFolder, withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 32).write(to: albumCacheFolder.appendingPathComponent("cached#0"))

        try FileManager.default.removeItem(at: CloudKitBlobCache.defaultBaseDir)

        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        let listed = try XCTUnwrap(manager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.albumID == albumID }, "the album must still be listed")
        XCTAssertEqual(listed.name, album.name)
        XCTAssertTrue(manager.isAlbumHidden(listed), "the album must come back hidden")
        XCTAssertFalse(manager.fetchAlbumsFromSources(includingHidden: false).contains { $0.albumID == albumID })
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.dirty, true, "it still has to be published")

        let queued = await queue.all().filter { $0.albumID == albumID }
        XCTAssertEqual(queued.map(\.recordName), ["m1#0"], "the queued capture still names the album")
        let pendingFile = await queue.pendingFileURL(recordName: "m1#0")
        XCTAssertNotNil(pendingFile)
    }

    /// "Erase All Data" clears the shared cache, and with it every album marker.
    func testClearAllRemovesTheAlbumMarkersRootItWasGiven() async throws {
        let markers = tempRoot.appendingPathComponent("markers", isDirectory: true)
        let marker = markers.appendingPathComponent("album-1/album.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: marker)
        let unrelated = CloudKitBlobCache(baseDir: cacheRoot, maxBytes: 10_000)
        try await unrelated.clearAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a cache not given the root leaves it")

        let cache = CloudKitBlobCache(baseDir: cacheRoot, albumMarkersDir: markers, maxBytes: 10_000)
        _ = try await cache.store(recordName: "a", changeTag: nil, albumID: "album", from: sourceFile(bytes: 40))
        try await cache.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: markers.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.path))
    }
}
