//
//  StorageUsageCalculatorTests.swift
//  EncameraCoreTests
//
//  The disk walk behind the Storage Insights screen, over a temp-directory fixture.
//

import XCTest
import CryptoKit
@testable import EncameraCore

/// Answers the calculator's iCloud Drive questions from a canned map, so no test
/// needs a ubiquity container.
private struct StubDriveSizer: ICloudDriveSizing {
    var isReachable: Bool
    /// Returned for every album directory. `nil` models a query that came back
    /// unreachable after the reachability check passed.
    var sizes: [String: Int64]?

    func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]? {
        sizes
    }
}

final class StorageUsageCalculatorTests: XCTestCase {

    private var tempRoot: URL!
    private var createdAlbumDirectories: [URL] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-calc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        for directory in createdAlbumDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdAlbumDirectories = []
        iCloudStorageModel.testContainerRootOverride = nil
    }

    // MARK: - Builders

    private func makeAlbumManager() -> MockAlbumManager {
        MockAlbumManager(keyManager: DemoKeyManager())
    }

    private func makeAlbum(_ storage: StorageType) -> Album {
        let key = PrivateKey(name: "key", keyBytes: Array(repeating: 4, count: 32), creationDate: Date())
        return Album(name: "Calc-\(UUID().uuidString)", storageOption: storage, creationDate: Date(), key: key,
                     albumID: storage == .cloudKit ? UUID().uuidString : nil)
    }

    /// Materializes a `.local` album's real directory (the calculator reads
    /// `album.storageURL`, not a fixture path) and fills it with `bytes`.
    private func seedLocalAlbum(_ album: Album, bytes: Int) throws {
        try seedLocalAlbum(album, files: ["media.encimage": bytes])
    }

    /// Materializes a `.local` album's real directory with named files.
    private func seedLocalAlbum(_ album: Album, files: [String: Int]) throws {
        let directory = album.storageURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdAlbumDirectories.append(directory)
        for (name, bytes) in files {
            try Data(repeating: 0xEE, count: bytes).write(to: directory.appendingPathComponent(name))
        }
    }

    private func seedDirectory(_ name: String, bytes: Int) throws -> URL {
        let directory = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: bytes).write(to: directory.appendingPathComponent("file"))
        return directory
    }

    /// Plants a file where the blob cache would have written it for `album`,
    /// bypassing the actor: the on-disk truth the calculator measures.
    private func plantCachedBlob(cacheDir: URL, album: Album, recordName: String, bytes: Int) throws -> URL {
        let folder = cacheDir.appendingPathComponent(album.storageURL.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(recordName)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        return url
    }

    private func sidecarFile() -> URL {
        tempRoot.appendingPathComponent("\(UUID().uuidString).encsizes")
    }

    /// The hashed stem the index store and both sidecars name an album's files by.
    private func indexStem(for album: Album) -> String {
        SHA256.hash(data: Data(album.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Allocated size, the measure the calculator reports — computed here
    /// independently so a test never grades the walk against its own arithmetic.
    /// - Parameter excluding: filenames the measured figure deliberately omits — the
    ///   blob cache's own `.cacheindex.json` is bookkeeping, not cached media.
    private func allocatedBytes(of directory: URL, excluding: Set<String> = []) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, !excluding.contains(url.lastPathComponent) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func allocatedBytes(ofFile url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
    }

    private func makeCalculator(albumManager: MockAlbumManager,
                                cacheDir: URL,
                                thumbnails: URL,
                                indexes: URL,
                                sidecars: [String: AlbumSizeSidecar] = [:],
                                driveSizing: ICloudDriveSizing = StubDriveSizer(isReachable: false, sizes: nil),
                                indexComponents: [String: Int] = [:]) -> StorageUsageCalculator {
        StorageUsageCalculator(
            albumManager: albumManager,
            cache: CloudKitBlobCache(baseDir: cacheDir, maxBytes: 500 * 1024 * 1024),
            driveSizing: driveSizing,
            thumbnailDirectory: thumbnails,
            indexDirectory: indexes,
            makeSidecar: { album in sidecars[album.id] ?? AlbumSizeSidecar(fileURL: URL(fileURLWithPath: "/dev/null/missing")) },
            indexComponentCount: { album in indexComponents[album.id] ?? 0 }
        )
    }

    private func entry(for album: Album, in breakdown: StorageUsageBreakdown) -> AlbumStorageBreakdown? {
        breakdown.albums.first { $0.albumID == album.id }
    }

    // MARK: - Tests

    func testBreakdownSumsEveryBucketFromDisk() async throws {
        let albumManager = makeAlbumManager()
        let local = makeAlbum(.local)
        try seedLocalAlbum(local, bytes: 4_000)
        albumManager.albumsOnDisk = [local]

        let cacheDir = tempRoot.appendingPathComponent("cache", isDirectory: true)
        let cache = CloudKitBlobCache(baseDir: cacheDir, maxBytes: 500 * 1024 * 1024)
        let source = tempRoot.appendingPathComponent("blob")
        try Data(repeating: 0xAA, count: 2_000).write(to: source)
        _ = try await cache.store(recordName: "r1", changeTag: nil, albumID: "album", from: source)

        let thumbnails = try seedDirectory("thumbs", bytes: 500)
        let indexes = try seedDirectory("indexes", bytes: 300)

        let calculator = StorageUsageCalculator(
            albumManager: albumManager,
            cache: cache,
            driveSizing: StubDriveSizer(isReachable: false, sizes: nil),
            thumbnailDirectory: thumbnails,
            indexDirectory: indexes,
            makeSidecar: { _ in AlbumSizeSidecar(fileURL: self.sidecarFile()) }
        )

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.localMediaBytes, try allocatedBytes(of: local.storageURL))
        XCTAssertEqual(breakdown.cachedCloudBytes,
                       try allocatedBytes(of: cacheDir, excluding: [".cacheindex.json"]))
        XCTAssertEqual(breakdown.thumbnailBytes, try allocatedBytes(of: thumbnails))
        XCTAssertEqual(breakdown.indexBytes, try allocatedBytes(of: indexes))
        XCTAssertEqual(breakdown.totalDeviceBytes,
                       breakdown.localMediaBytes + breakdown.cachedCloudBytes
                       + breakdown.thumbnailBytes + breakdown.indexBytes)
    }

    /// The regression guard for the most likely silent under-report.
    func testHiddenAlbumsAreIncludedInTheTotal() async throws {
        let albumManager = makeAlbumManager()
        let visible = makeAlbum(.local)
        let hidden = makeAlbum(.local)
        try seedLocalAlbum(visible, bytes: 1_000)
        try seedLocalAlbum(hidden, bytes: 1_000)
        albumManager.albumsOnDisk = [visible]
        albumManager.hiddenAlbumsOnDisk = [hidden]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("no-thumbs"),
                                        indexes: tempRoot.appendingPathComponent("no-indexes"))

        let breakdown = try await calculator.breakdown()

        let expected = try allocatedBytes(of: visible.storageURL) + allocatedBytes(of: hidden.storageURL)
        XCTAssertEqual(breakdown.localMediaBytes, expected, "A hidden album's bytes still occupy the disk")
        XCTAssertEqual(albumManager.fetchIncludingHiddenCalls, [true])
        XCTAssertEqual(breakdown.albums.count, 2, "The hidden album gets its own entry too")
    }

    func testMissingDirectoriesContributeZero() async throws {
        let albumManager = makeAlbumManager()
        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("never-created"),
                                        thumbnails: tempRoot.appendingPathComponent("never-created-2"),
                                        indexes: tempRoot.appendingPathComponent("never-created-3"))

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.totalDeviceBytes, 0)
        XCTAssertTrue(breakdown.isEmpty)
        XCTAssertEqual(breakdown.iCloudDriveMedia, .zero, "No Drive albums means zero, not unknowable")
        XCTAssertEqual(breakdown.cloudBytes, 0)
    }

    func testCancellationStopsTheWalkAndThrows() async throws {
        let albumManager = makeAlbumManager()
        for _ in 0..<200 {
            let album = makeAlbum(.local)
            try seedLocalAlbum(album, bytes: 128)
            albumManager.albumsOnDisk.append(album)
        }
        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        let task = Task { try await calculator.breakdown() }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled walk must throw rather than return a partial breakdown")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCalculatorDoesNotRunOnTheMainActor() async throws {
        let albumManager = makeAlbumManager()
        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        _ = try await MainActor.run { Task { try await calculator.breakdown() } }.value

        let onMain = await calculator._testRanOnMainThread()
        XCTAssertFalse(onMain, "The disk walk must not block the UI, even when called from the main actor")
    }

    func testReclaimableExcludesLocalMediaEndToEnd() async throws {
        let albumManager = makeAlbumManager()
        let local = makeAlbum(.local)
        try seedLocalAlbum(local, bytes: 8_000)
        albumManager.albumsOnDisk = [local]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        let breakdown = try await calculator.breakdown()

        XCTAssertGreaterThan(breakdown.localMediaBytes, 0)
        XCTAssertEqual(breakdown.reclaimableBytes, 0, "Local media is never offered up for reclaim")
    }

    // MARK: - Per album, per media type

    func testLocalAlbumsAreTabulatedPerAlbumAndPerMediaType() async throws {
        let albumManager = makeAlbumManager()
        let first = makeAlbum(.local)
        let second = makeAlbum(.local)
        try seedLocalAlbum(first, files: ["still.encimage": 1_000,
                                          "clip.encvideo": 6_000,
                                          "live.encimage": 2_000,
                                          "live.encvideo": 9_000])
        try seedLocalAlbum(second, files: ["only.encvideo": 3_000])
        albumManager.albumsOnDisk = [first, second]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"))

        let breakdown = try await calculator.breakdown()

        let firstDir = first.storageURL
        let expectedFirst = MediaTypeBytes(
            photoBytes: try allocatedBytes(ofFile: firstDir.appendingPathComponent("still.encimage"))
                + allocatedBytes(ofFile: firstDir.appendingPathComponent("live.encimage"))
                + allocatedBytes(ofFile: firstDir.appendingPathComponent("live.encvideo")),
            videoBytes: try allocatedBytes(ofFile: firstDir.appendingPathComponent("clip.encvideo"))
        )
        let expectedSecond = MediaTypeBytes(
            videoBytes: try allocatedBytes(ofFile: second.storageURL.appendingPathComponent("only.encvideo"))
        )

        let firstEntry = try XCTUnwrap(entry(for: first, in: breakdown))
        XCTAssertEqual(firstEntry.storageOption, .local)
        XCTAssertEqual(firstEntry.mediaBytes, expectedFirst, "A Live Photo's video track counts as photo")
        XCTAssertEqual(firstEntry.cachedBytes, .zero)
        XCTAssertEqual(entry(for: second, in: breakdown)?.mediaBytes, expectedSecond)
        XCTAssertEqual(breakdown.localMedia, expectedFirst + expectedSecond)
        XCTAssertEqual(breakdown.localMediaBytes,
                       try allocatedBytes(of: first.storageURL) + allocatedBytes(of: second.storageURL))
    }

    func testCloudKitAlbumsAreTabulatedFromTheirSidecars() async throws {
        let albumManager = makeAlbumManager()
        let first = makeAlbum(.cloudKit)
        let second = makeAlbum(.cloudKit)
        albumManager.albumsOnDisk = [first, second]

        let firstSidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await firstSidecar.replace(with: ["a#0": 1_000, "a#1": 4_000, "b#1": 250])
        let secondSidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await secondSidecar.replace(with: ["c#0": 10])

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [first.id: firstSidecar, second.id: secondSidecar])

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(entry(for: first, in: breakdown)?.mediaBytes,
                       MediaTypeBytes(photoBytes: 5_000, videoBytes: 250),
                       "The live pair a#0/a#1 is all photo; b#1 is a standalone video")
        XCTAssertEqual(entry(for: second, in: breakdown)?.mediaBytes, MediaTypeBytes(photoBytes: 10))
        XCTAssertEqual(breakdown.cloudKitMedia, MediaTypeBytes(photoBytes: 5_010, videoBytes: 250))
        XCTAssertEqual(breakdown.cloudBytes, 5_260)
        XCTAssertEqual(breakdown.totalDeviceBytes, 0, "Cloud bytes are not on this device")
    }

    /// The sync path never writes a sidecar for an album with nothing in it, so an
    /// empty CloudKit album must read as zero and not hold the whole figure hostage.
    func testEmptyCloudKitAlbumWithoutASidecarIsAKnownZero() async throws {
        let albumManager = makeAlbumManager()
        let empty = makeAlbum(.cloudKit)
        let measured = makeAlbum(.cloudKit)
        albumManager.albumsOnDisk = [empty, measured]

        let sidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await sidecar.replace(with: ["a#1": 300])

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [measured.id: sidecar],
                                        indexComponents: [empty.id: 0])

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(entry(for: empty, in: breakdown)?.mediaBytes, .zero)
        XCTAssertEqual(breakdown.cloudKitMedia, MediaTypeBytes(videoBytes: 300))
        XCTAssertEqual(breakdown.cloudBytes, 300)
    }

    /// No backfill: an album whose index holds media but which has no sidecar has
    /// never been measured, and one unknowable album makes the CloudKit figure
    /// unknowable rather than under-reported.
    func testCloudKitAlbumWithoutASidecarMakesTheCloudKitFigureUnknowable() async throws {
        let albumManager = makeAlbumManager()
        let measured = makeAlbum(.cloudKit)
        let unmeasured = makeAlbum(.cloudKit)
        let local = makeAlbum(.local)
        try seedLocalAlbum(local, bytes: 2_000)
        albumManager.albumsOnDisk = [measured, unmeasured, local]

        let sidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await sidecar.replace(with: ["a#0": 700])

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [measured.id: sidecar],
                                        indexComponents: [unmeasured.id: 2])

        let breakdown = try await calculator.breakdown()

        XCTAssertNil(breakdown.cloudKitMedia)
        XCTAssertNil(breakdown.cloudBytes)
        XCTAssertEqual(entry(for: measured, in: breakdown)?.mediaBytes, MediaTypeBytes(photoBytes: 700),
                       "The measured album's own entry is still exact")
        let unmeasuredEntry = try XCTUnwrap(entry(for: unmeasured, in: breakdown))
        XCTAssertNil(unmeasuredEntry.mediaBytes)
        XCTAssertNil(unmeasuredEntry.totalBytes)
        XCTAssertEqual(breakdown.localMediaBytes, try allocatedBytes(of: local.storageURL),
                       "The device buckets do not depend on the cloud")
    }

    func testCachedBlobsAreAttributedPerAlbumAndPerMediaType() async throws {
        let albumManager = makeAlbumManager()
        let first = makeAlbum(.cloudKit)
        let second = makeAlbum(.cloudKit)
        albumManager.albumsOnDisk = [first, second]
        let cacheDir = tempRoot.appendingPathComponent("cache", isDirectory: true)

        let firstPhoto = try plantCachedBlob(cacheDir: cacheDir, album: first, recordName: "x#0", bytes: 1_000)
        let secondVideo = try plantCachedBlob(cacheDir: cacheDir, album: second, recordName: "y#1", bytes: 3_000)
        let secondChunk = try plantCachedBlob(cacheDir: cacheDir, album: second, recordName: "y#1#c0", bytes: 5_000)
        let strayFolder = cacheDir.appendingPathComponent("unclaimed", isDirectory: true)
        try FileManager.default.createDirectory(at: strayFolder, withIntermediateDirectories: true)
        let stray = strayFolder.appendingPathComponent("z#0")
        try Data(repeating: 0x01, count: 400).write(to: stray)

        let firstSidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await firstSidecar.replace(with: [:])
        let secondSidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await secondSidecar.replace(with: [:])

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: cacheDir,
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [first.id: firstSidecar, second.id: secondSidecar])

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(entry(for: first, in: breakdown)?.cachedBytes,
                       MediaTypeBytes(photoBytes: try allocatedBytes(ofFile: firstPhoto)))
        XCTAssertEqual(entry(for: second, in: breakdown)?.cachedBytes,
                       MediaTypeBytes(videoBytes: try allocatedBytes(ofFile: secondVideo) + allocatedBytes(ofFile: secondChunk)),
                       "A chunk file belongs to its parent record's type")
        XCTAssertEqual(breakdown.cachedCloud.photoBytes,
                       try allocatedBytes(ofFile: firstPhoto) + allocatedBytes(ofFile: stray))
        XCTAssertEqual(breakdown.cachedCloudBytes,
                       try allocatedBytes(of: cacheDir, excluding: [".cacheindex.json"]))
        XCTAssertEqual(breakdown.albums.reduce(0) { $0 + $1.cachedBytes.totalBytes },
                       breakdown.cachedCloudBytes - (try allocatedBytes(ofFile: stray)))
    }

    func testIndexBytesAreAttributedPerAlbum() async throws {
        let albumManager = makeAlbumManager()
        let album = makeAlbum(.local)
        let other = makeAlbum(.local)
        try seedLocalAlbum(album, bytes: 10)
        try seedLocalAlbum(other, bytes: 10)
        albumManager.albumsOnDisk = [album, other]

        let indexes = tempRoot.appendingPathComponent("indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
        let stem = indexStem(for: album)
        let index = indexes.appendingPathComponent("\(stem).encindex")
        let sizes = indexes.appendingPathComponent("\(stem).encsizes")
        let cover = indexes.appendingPathComponent("\(stem).enccover")
        try Data(repeating: 0x22, count: 5_000).write(to: index)
        try Data(repeating: 0x33, count: 100).write(to: sizes)
        try Data(repeating: 0x44, count: 40).write(to: cover)
        try Data(repeating: 0x55, count: 9_000).write(to: indexes.appendingPathComponent("\(indexStem(for: other)).encindex"))
        try Data(repeating: 0x66, count: 300).write(to: indexes.appendingPathComponent("orphan.encindex"))

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: indexes)

        let breakdown = try await calculator.breakdown()

        let expected = try allocatedBytes(ofFile: index) + allocatedBytes(ofFile: sizes) + allocatedBytes(ofFile: cover)
        XCTAssertEqual(entry(for: album, in: breakdown)?.indexBytes, expected)
        XCTAssertEqual(breakdown.indexBytes, try allocatedBytes(of: indexes),
                       "The global figure still walks the whole directory, orphans included")
        XCTAssertLessThan(breakdown.albums.reduce(0) { $0 + $1.indexBytes }, breakdown.indexBytes)
    }

    // MARK: - iCloud Drive

    func testICloudDriveAlbumsAreMeasuredInTheCloudAndExcludedFromTheDevice() async throws {
        iCloudStorageModel.testContainerRootOverride = tempRoot.appendingPathComponent("ubiquity", isDirectory: true)
        let albumManager = makeAlbumManager()
        let drive = makeAlbum(.icloud)
        let cloudKit = makeAlbum(.cloudKit)
        albumManager.albumsOnDisk = [drive, cloudKit]

        let sidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await sidecar.replace(with: ["k#0": 100])
        let sizer = StubDriveSizer(isReachable: true, sizes: [
            "still.encimage": 1_000,
            "live.encimage": 200,
            "live.encvideo": 3_000,
            "clip.encvideo": 7_000,
            drive.storageURL.lastPathComponent: 4_096,
            ".Trash": 50,
        ])

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [cloudKit.id: sidecar],
                                        driveSizing: sizer)

        let breakdown = try await calculator.breakdown()

        let expected = MediaTypeBytes(photoBytes: 4_200, videoBytes: 7_000)
        XCTAssertEqual(breakdown.iCloudDriveMedia, expected, "Non-media names are dropped, not counted as other")
        XCTAssertEqual(entry(for: drive, in: breakdown)?.mediaBytes, expected)
        XCTAssertEqual(breakdown.cloudKitMedia, MediaTypeBytes(photoBytes: 100))
        XCTAssertEqual(breakdown.cloudBytes, 11_300)
        XCTAssertEqual(breakdown.cloudKitShareOfCloud, 100.0 / 11_300.0)
        XCTAssertEqual(breakdown.totalDeviceBytes, 0, "Drive copies never enter a device bucket")
        XCTAssertEqual(breakdown.legacyICloudDriveAlbumCount, 1)
    }

    /// With no ubiquity container the album URL is never built (it would trap), the
    /// Drive figure is unknowable, and the CloudKit figure is unaffected.
    func testUnreachableICloudDriveMakesTheDriveFigureUnknowable() async throws {
        let albumManager = makeAlbumManager()
        let cloudKit = makeAlbum(.cloudKit)
        albumManager.albumsOnDisk = [makeAlbum(.icloud), makeAlbum(.icloud), cloudKit]

        let sidecar = AlbumSizeSidecar(fileURL: sidecarFile())
        try await sidecar.replace(with: ["k#1": 900])

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        sidecars: [cloudKit.id: sidecar],
                                        driveSizing: StubDriveSizer(isReachable: false, sizes: nil))

        let breakdown = try await calculator.breakdown()

        XCTAssertEqual(breakdown.legacyICloudDriveAlbumCount, 2)
        XCTAssertNil(breakdown.iCloudDriveMedia)
        XCTAssertNil(breakdown.cloudBytes)
        XCTAssertEqual(breakdown.cloudKitMedia, MediaTypeBytes(videoBytes: 900))
        XCTAssertEqual(breakdown.totalDeviceBytes, 0)
        XCTAssertEqual(breakdown.albums.filter { $0.storageOption == .icloud }.count, 2)
        XCTAssertTrue(breakdown.albums.filter { $0.storageOption == .icloud }.allSatisfy { $0.mediaBytes == nil })
    }

    func testReachableICloudDriveThatAnswersNothingIsUnknowable() async throws {
        iCloudStorageModel.testContainerRootOverride = tempRoot.appendingPathComponent("ubiquity", isDirectory: true)
        let albumManager = makeAlbumManager()
        albumManager.albumsOnDisk = [makeAlbum(.icloud)]

        let calculator = makeCalculator(albumManager: albumManager,
                                        cacheDir: tempRoot.appendingPathComponent("cache"),
                                        thumbnails: tempRoot.appendingPathComponent("thumbs"),
                                        indexes: tempRoot.appendingPathComponent("indexes"),
                                        driveSizing: StubDriveSizer(isReachable: true, sizes: nil))

        let breakdown = try await calculator.breakdown()

        XCTAssertNil(breakdown.iCloudDriveMedia)
        XCTAssertNil(breakdown.cloudBytes)
    }
}
