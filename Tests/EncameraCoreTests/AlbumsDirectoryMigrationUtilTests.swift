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
        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_once")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("Album_once")))
    }

    func testSkipsWhenDestinationAlreadyExists() throws {
        _ = try seedAlbum("Album_dup", at: rootURL, withFile: "stale.bin")
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedAlbum("Album_dup", at: albumsURL, withFile: "fresh.bin")

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        let freshFile = albumsURL.appendingPathComponent("Album_dup").appendingPathComponent("fresh.bin")
        XCTAssertTrue(exists(freshFile))
        let staleInDest = albumsURL.appendingPathComponent("Album_dup").appendingPathComponent("stale.bin")
        XCTAssertFalse(exists(staleInDest))
        XCTAssertTrue(exists(rootURL.appendingPathComponent("Album_dup")))
    }

    func testLeavesTheRootAloneWhenThereIsNothingToMigrate() throws {
        _ = try seedPlainDirectory("thumbs", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(albumsURL), "an empty albums/ planted in iCloud Drive reads as legacy data to the existing-data probe")
    }

    func testReturnsFalseWhenAlbumsURLCannotBeCreated() throws {
        _ = try seedAlbum("Album_good", at: rootURL)
        let blockedAlbumsURL = rootURL.appendingPathComponent("blocked")
        XCTAssertTrue(FileManager.default.createFile(atPath: blockedAlbumsURL.path, contents: Data()))

        XCTAssertFalse(util.performMigration(at: rootURL, into: blockedAlbumsURL))

        XCTAssertTrue(exists(rootURL.appendingPathComponent("Album_good")))
    }

    func testIgnoresAlbumAlreadyUnderAlbumsURL() throws {
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedAlbum("Album_inplace", at: albumsURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_inplace")))
    }

    /// Albums created before album-name encryption sit at the storage root under
    /// their PLAINTEXT name — no `Album_` prefix. They are still albums and still
    /// belong under `albums/`.
    func testMovesLegacyPlaintextAlbumDirectoriesIntoAlbumsSubdir() throws {
        _ = try seedAlbum("met", at: rootURL)
        _ = try seedAlbum("koti", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(rootURL.appendingPathComponent("met")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("koti")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("met")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("koti")))

        let sentinel = albumsURL.appendingPathComponent("met").appendingPathComponent("sentinel.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02, 0x03]))
    }

    /// The upgrade path this fix exists for: a device that ran the V1 migration
    /// recorded it as done while leaving every plaintext-named album at the root.
    /// Reusing the V1 flag key would strand those devices forever — the widened
    /// migration would be skipped before it ever enumerated anything.
    func testADeviceThatCompletedTheV1MigrationIsNotConsideredMigrated() throws {
        let suiteName = "AlbumsDirMigrationV1Flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([StorageType.local.rawValue, StorageType.icloud.rawValue],
                     forKey: "completedAlbumsDirectoryMigrationV1")

        let util = AlbumsDirectoryMigrationUtil(userDefaults: defaults)

        XCTAssertFalse(util.hasMigrated(.local))
        XCTAssertFalse(util.hasMigrated(.icloud))
    }

    /// The flag still has to work as a flag: once the widened migration records a
    /// storage type, it is not repeated.
    func testRecordsCompletionUnderTheCurrentFlagKey() throws {
        let suiteName = "AlbumsDirMigrationV2Flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let util = AlbumsDirectoryMigrationUtil(userDefaults: defaults)
        XCTAssertFalse(util.hasMigrated(.local))

        util.markMigrated(.local)

        XCTAssertTrue(util.hasMigrated(.local))
        XCTAssertFalse(util.hasMigrated(.icloud))
    }

    /// A plaintext album name can contain dots. The reverse-DNS exclusion must
    /// not strand these at the root.
    func testMovesPlaintextAlbumsWithDottedNamesIntoAlbumsSubdir() throws {
        _ = try seedAlbum("Trip 2.0", at: rootURL)
        _ = try seedAlbum("Nov. 2023", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(rootURL.appendingPathComponent("Trip 2.0")))
        XCTAssertFalse(exists(rootURL.appendingPathComponent("Nov. 2023")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Trip 2.0")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Nov. 2023")))
    }

    /// Every name here round-trips through `URL.lastPathComponent` and
    /// `appendingPathComponent` on the way from root to `albums/`. Percent,
    /// hash, ampersand, question mark and colon are the characters a URL
    /// encodes; trailing dot and space, decomposed Unicode, backslash and the
    /// base64 alphabet are the rest of what a keyboard or an encrypted name
    /// can produce.
    func testMovesAlbumsWithURLSensitiveNamesIntoAlbumsSubdir() throws {
        let names = [
            "Summer 100%", "Q&A #1?", "Trip: Rome", "Nov.", "Trip ",
            "Ka\u{0308}se", "Trip\\Rome", "Trip;Rome", "Album_abc+def==",
        ]
        for name in names {
            _ = try seedAlbum(name, at: rootURL)
        }

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        for name in names {
            XCTAssertFalse(exists(rootURL.appendingPathComponent(name)), "\(name.debugDescription) left at root")
            let sentinel = albumsURL.appendingPathComponent(name).appendingPathComponent("sentinel.bin")
            XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02, 0x03]), "\(name.debugDescription) not under albums/")
        }
    }

    /// A dot-prefixed plaintext album is an album; iCloud Drive's `.Trash` is
    /// the one dot-prefixed sibling at a root that must never move.
    func testMovesDotPrefixedAlbumsButLeavesTrashAtRoot() throws {
        _ = try seedAlbum(".secret", at: rootURL)
        _ = try seedPlainDirectory(".Trash", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertFalse(exists(rootURL.appendingPathComponent(".secret")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent(".secret")))
        XCTAssertTrue(exists(rootURL.appendingPathComponent(".Trash")))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent(".Trash")))
    }

    /// A ".secret" album 2.10.0 left at the root moves into `albums/` with
    /// its contents; filesystem bookkeeping beside it stays where it is.
    func testDottedPlaintextAlbumIsMigrated() throws {
        _ = try seedAlbum(".secret", at: rootURL)
        _ = try seedPlainDirectory(".fseventsd", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        let sentinel = albumsURL.appendingPathComponent(".secret").appendingPathComponent("sentinel.bin")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x01, 0x02, 0x03]))
        XCTAssertFalse(exists(rootURL.appendingPathComponent(".secret")))
        XCTAssertTrue(exists(rootURL.appendingPathComponent(".fseventsd")))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent(".fseventsd")))
    }

    func testLeavesReverseDNSCacheDirectoriesUntouched() throws {
        _ = try seedPlainDirectory("me.freas.encamera.revenuecat.etags", at: rootURL)
        _ = try seedAlbum("Album_aaa", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(rootURL.appendingPathComponent("me.freas.encamera.revenuecat.etags")))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent("me.freas.encamera.revenuecat.etags")))
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_aaa")))
    }

    func testRecoversRevenueCatDirectoryMisplacedByV2Migration() throws {
        try FileManager.default.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        _ = try seedPlainDirectory("me.freas.encamera.revenuecat.etags", at: albumsURL)
        _ = try seedAlbum("Album_aaa", at: albumsURL)

        util.performMigration(at: rootURL, into: albumsURL)

        XCTAssertTrue(exists(rootURL.appendingPathComponent("me.freas.encamera.revenuecat.etags")),
                       "RevenueCat directory should be moved back to root")
        XCTAssertFalse(exists(albumsURL.appendingPathComponent("me.freas.encamera.revenuecat.etags")),
                        "RevenueCat directory should no longer be under albums/")
        XCTAssertTrue(exists(albumsURL.appendingPathComponent("Album_aaa")),
                       "Real albums must stay under albums/")
    }

    func testLeavesAnyRevenueCatVariantAtRoot() throws {
        _ = try seedPlainDirectory("RevenueCat_Cache", at: rootURL)
        _ = try seedAlbum("Album_aaa", at: rootURL)

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(rootURL.appendingPathComponent("RevenueCat_Cache")))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent("RevenueCat_Cache")))
    }

    func testIgnoresFilesThatLookLikeAlbums() throws {
        let bogus = rootURL.appendingPathComponent("Album_justAFile")
        XCTAssertTrue(FileManager.default.createFile(atPath: bogus.path, contents: Data()))

        XCTAssertTrue(util.performMigration(at: rootURL, into: albumsURL))

        XCTAssertTrue(exists(bogus))
        XCTAssertFalse(exists(albumsURL.appendingPathComponent("Album_justAFile")))
    }
}
