import XCTest
@testable import EncameraCore

final class AlbumsDirectoryMigrationUtilTests: XCTestCase {

    private var fixtureRoot: URL!
    private var rootURL: URL!
    private var albumsURL: URL!
    private var util: AlbumsDirectoryMigrationUtil!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("AlbumsDirMigrationTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = fixtureRoot.appendingPathComponent("root", isDirectory: true)
        albumsURL = rootURL.appendingPathComponent("albums", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let suiteName = "AlbumsDirMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        util = AlbumsDirectoryMigrationUtil(userDefaults: defaults)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
        fixtureRoot = nil
        rootURL = nil
        albumsURL = nil
        util = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func seedAlbum(_ name: String, at parent: URL, withFile fileName: String = "sentinel.bin") throws -> URL {
        let albumURL = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: albumURL, withIntermediateDirectories: true)
        let filePath = albumURL.appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: filePath.path, contents: Data([0x01, 0x02, 0x03])))
        return albumURL
    }

    private func seedPlainDirectory(_ name: String, at parent: URL) throws -> URL {
        let dirURL = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        return dirURL
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Tests

    func testMovesAlbumPrefixedDirectoriesIntoAlbumsSubdir() throws {
        _ = try seedAlbum("Album_aaa", at: rootURL)
        _ = try seedAlbum("Album_bbb", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_aaa")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_bbb")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_aaa")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_bbb")))

        // Contents preserved.
        let sentinel = albumsURL.appendingPathComponent("Album_aaa").appendingPathComponent("sentinel.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02, 0x03]))
    }

    func testLeavesNonAlbumSiblingsUntouched() throws {
        _ = try seedPlainDirectory("preview_thumbnails", at: rootURL)
        _ = try seedPlainDirectory("RevenueCat", at: rootURL)
        _ = try seedAlbum("Album_xxx", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(rootURL.appendingPathComponent("preview_thumbnails")))
        XCTAssertTrue(exists(rootURL.appendingPathComponent("RevenueCat")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_xxx")))
    }

    func testIsIdempotent() throws {
        _ = try seedAlbum("Album_once", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))
        // Second call: nothing to move, still succeeds.
        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_once")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_once")))
    }

    func testSkipsWhenDestinationAlreadyExists() throws {
        // Simulate crash-recovery state: a partially-migrated album exists at dest,
        // and a stale copy still sits at root. Migration must not clobber the dest.
        _ = try seedAlbum("Album_dup", at: rootURL, withFile: "stale.bin")
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedAlbum("Album_dup", at: albumsURL, withFile: "fresh.bin")

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        // Dest retains its existing content.
        let freshFile = albumsURL.appendingPathComponent("Album_dup").appendingPathComponent("fresh.bin")
        XCTAssertTrue(exists(freshFile))
        let staleInDest = albumsURL.appendingPathComponent("Album_dup").appendingPathComponent("stale.bin")
        XCTAssertFalse(exists(staleInDest))
        // Stale root copy remains; operator can resolve manually.
        XCTAssertTrue(exists(rootURL.appendingPathComponent("Album_dup")))
    }

    func testReturnsFalseWhenAlbumsURLCannotBeCreated() throws {
        _ = try seedAlbum("Album_good", at: rootURL)
        // Point albumsURL at a non-creatable location — a file where a directory should be.
        let blockedAlbumsURL = rootURL.appendingPathComponent("blocked")
        XCTAssertTrue(FileManager.default.createFile(atPath: blockedAlbumsURL.path, contents: Data()))

        XCTAssertFalse(util.performMigration(at: rootURL, into: blockedAlbumsURL))

        // Source album untouched — safe for next-launch retry.
        XCTAssertTrue(exists(rootURL.appendingPathComponent("Album_good")))
    }

    func testIgnoresAlbumAlreadyUnderAlbumsURL() throws {
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedAlbum("Album_inplace", at: albumsURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_inplace")))
    }

    func testIgnoresFilesThatLookLikeAlbums() throws {
        let bogus = rootURL.appendingPathComponent("Album_justAFile")
        XCTAssertTrue(FileManager.default.createFile(atPath: bogus.path, contents: Data()))

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(bogus))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent("Album_justAFile")))
    }
}
