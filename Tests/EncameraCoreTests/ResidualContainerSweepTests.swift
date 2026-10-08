//
//  ResidualContainerSweepTests.swift
//  EncameraCoreTests
//
//  The erase step that names nothing.
//
//  Every other step in `EraserUtils` erases a surface someone registered, and the
//  gap that leaves is not hypothetical: the CloudKit adapter wrote a copy of every
//  fetched chunk into a tmp directory that no erase step and no verifier knew
//  about, so "Erase All Data" left one file per chunk of every video ever played.
//  These tests are about the sweep that does not need to be told.
//

import XCTest
@testable import EncameraCore

final class ResidualContainerSweepTests: XCTestCase {

    private var root: URL!
    private let eraser = DefaultLocalDataEraser(keyManager: DemoKeyManager(),
                                                fileAccess: InteractableMediaFileAccess())

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func seed(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 32).write(to: url)
        return url
    }

    /// Everything under the root goes, at any depth, whatever it is called.
    func testSweepRemovesEveryFileUnderTheRootAtAnyDepth() throws {
        let planted = [
            "Documents/album/photo.encrypted",
            "Library/Caches/CloudKitBlobs/hash/blob#1",
            "Library/Application Support/EncameraAnalytics/events.sqlite",
            "tmp/ckassets/ckasset-1234-encChunk",
            "tmp/decrypted/movie.mov",
            "Library/Caches/a/b/c/d/e/deeply-nested.bin",
            "loose-file-at-the-root.bin"
        ]
        for path in planted { try seed(path) }

        eraser.eraseResidualContainerFiles(roots: [root])

        for path in planted {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                           "\(path) survived the sweep")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [],
                       "the root should be empty")
    }

    /// `Preferences` is `cfprefsd`'s, not ours. Deleting the plists underneath a
    /// running preferences daemon corrupts the domain rather than clearing it —
    /// `eraseUserDefaults()` is how those are cleared.
    func testSweepLeavesThePreferencesDirectoryAlone() throws {
        try seed("Library/Preferences/me.freas.encamera.plist")
        try seed("Library/Caches/junk.bin")

        eraser.eraseResidualContainerFiles(roots: [root])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Library/Preferences/me.freas.encamera.plist").path),
            "preferences must survive the file sweep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Library/Caches/junk.bin").path))
    }

    /// A move to iCloud decrypts a large video into `tmp/migration-enc3-<uuid>/`
    /// to re-encrypt it. A crash or jetsam there skips its cleanup, so the next
    /// launch's temp-file cleanup removes the directory.
    @MainActor
    func testLaunchSweepRemovesLeftoverMigrationEnc3Directories() throws {
        let tmp = FileManager.default.temporaryDirectory
        let leftover = tmp.appendingPathComponent("\(MigrationReencryptScratch.directoryPrefix)\(UUID().uuidString)",
                                                  isDirectory: true)
        let unrelated = tmp.appendingPathComponent("sweep-unrelated-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: leftover)
            try? FileManager.default.removeItem(at: unrelated)
        }
        for dir in [leftover, unrelated] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x2A, count: 32).write(to: leftover.appendingPathComponent("video.plain"))
        try Data(repeating: 0x2A, count: 32).write(to: leftover.appendingPathComponent("video.enc3"))
        try Data(repeating: 0x2A, count: 32).write(to: unrelated.appendingPathComponent("keep.bin"))

        TempFileAccess.cleanupTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "a leftover migration-enc3 directory survived the launch sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.bin").path),
                      "the sweep only removes migration-enc3 directories")
    }

    /// The same cleanup runs when the app goes to the background, possibly while
    /// a move is re-encrypting; the directory that move is using stays.
    func testMigrationEnc3SweepLeavesADirectoryInUse() throws {
        let inUse = try MigrationReencryptScratch.makeDirectory(in: root)
        let leftover = root.appendingPathComponent("\(MigrationReencryptScratch.directoryPrefix)\(UUID().uuidString)",
                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        XCTAssertEqual(MigrationReencryptScratch.sweepLeftovers(in: root), 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: inUse.path), "a directory in use must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))

        MigrationReencryptScratch.release(inUse)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inUse.path))
    }

    /// The roots have to resolve to something real, or every test above passes
    /// against a sweep that runs over nothing.
    func testContainerRootsIncludeTheAppHomeDirectory() {
        let roots = EraserUtils.containerRoots.map(\.path)
        XCTAssertTrue(roots.contains(URL(fileURLWithPath: NSHomeDirectory()).path),
                      "the sweep must cover the app's own container; roots were \(roots)")
    }
}
