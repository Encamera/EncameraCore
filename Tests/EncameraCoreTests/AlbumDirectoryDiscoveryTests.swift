//
//  AlbumDirectoryDiscoveryTests.swift
//  EncameraCoreTests
//
//  What `enumerateAlbumsDirectory` counts as an album on disk.
//
//  Driven through a test-only `DataStorageModel` rather than one of the shipping
//  three: the rule under test lives entirely in the protocol extension, and both
//  real models resolve `rootURL` to somewhere a test must not write — the app's
//  Documents directory for `.local`, the ubiquity container for `.icloud`. A
//  conforming type whose `rootURL` is a scratch directory exercises the real
//  implementation with nothing stubbed out.
//

import XCTest
@testable import EncameraCore

/// Substitutes only `rootURL`. Everything the assertions touch —
/// `albumsURL`, `enumerateAlbumsDirectory` — is the production protocol
/// extension, unmodified.
private struct ScratchStorageModel: DataStorageModel {
    nonisolated(unsafe) static var scratchRoot: URL!

    static var rootURL: URL { scratchRoot }

    var storageType: StorageType { .local }
    var album: Album
    var baseURL: URL { Self.albumsURL.appendingPathComponent(album.encryptedPathComponent) }

    init(album: Album) {
        self.album = album
    }
}

final class AlbumDirectoryDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("AlbumDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ScratchStorageModel.scratchRoot = root
    }

    override func tearDownWithError() throws {
        ScratchStorageModel.scratchRoot = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func seedDirectory(_ name: String, at parent: URL) throws {
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func seedAlbumsSubdirectory() throws -> URL {
        let albums = root.appendingPathComponent("albums", isDirectory: true)
        try FileManager.default.createDirectory(at: albums, withIntermediateDirectories: true)
        return albums
    }

    private func discoveredNames() -> Set<String> {
        Set(ScratchStorageModel.enumerateAlbumsDirectory().map { $0.lastPathComponent })
    }

    /// The bug: albums created before album-name encryption have no `Album_`
    /// prefix, so the prefix filter dropped them and the user's grid came up
    /// empty while the directories sat in iCloud Drive, intact.
    func testDiscoversLegacyPlaintextAlbumDirectoriesAtRoot() throws {
        try seedDirectory("met", at: root)
        try seedDirectory("koti", at: root)

        XCTAssertEqual(discoveredNames(), ["met", "koti"])
    }

    func testDiscoversEncryptedAlbumDirectoriesUnderAlbumsSubdir() throws {
        try seedDirectory("Album_aaa", at: try seedAlbumsSubdirectory())

        XCTAssertEqual(discoveredNames(), ["Album_aaa"])
    }

    /// Both layouts at once: an already-migrated album and one the migration has
    /// not reached yet must both appear, and `albums` itself must not be mistaken
    /// for an album now that the prefix no longer excludes it.
    func testDiscoversBothLayoutsAndNeverTheAlbumsContainerItself() throws {
        try seedDirectory("Album_aaa", at: try seedAlbumsSubdirectory())
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["Album_aaa", "met"])
    }

    func testExcludesNonAlbumSiblings() throws {
        try seedDirectory(AppConstants.previewDirectory, at: root)
        try seedDirectory("thumbs", at: root)
        try seedDirectory("RevenueCat", at: root)
        try seedDirectory("Inbox", at: root)
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["met"])
    }

    func testExcludesFilesAndBookkeepingDotDirectories() throws {
        for name in [".Trash", ".fseventsd", ".Spotlight-V100", ".me.freas.encamera.revenuecat.etags"] {
            try seedDirectory(name, at: root)
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent("loose.encimage").path, contents: Data()))
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["met"])
    }

    /// 2.10.0 lists a pre-encryption album whose name starts with a dot, so it
    /// must still be listed after the upgrade, both where 2.10.0's migration
    /// put it (`albums/`) and at the root on a device that never ran it.
    func testDiscoversADotPrefixedPreEncryptionAlbum() throws {
        try seedDirectory(".secret", at: try seedAlbumsSubdirectory())
        try seedDirectory(".hidden trip", at: root)
        try seedDirectory(".Trash", at: root)

        XCTAssertEqual(discoveredNames(), [".secret", ".hidden trip"])
    }

    /// End to end through the real listing: a dot-prefixed plaintext album in
    /// local storage is listed, with its media counted.
    @MainActor
    func testFetchAlbumsFromSourcesListsADotPrefixedLocalAlbumWithItsMedia() throws {
        let key = PrivateKey(name: "key", keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) },
                             creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        let name = ".secret-\(UUID().uuidString)"
        let directory = LocalStorageModel.albumsURL.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("\(UUID().uuidString).\(MediaType.photo.encryptedFileExtension)").path,
            contents: Data([0x01])))

        let listed = albumManager.fetchAlbumsFromSources(includingHidden: true).first { $0.name == name }

        let album = try XCTUnwrap(listed, "the dot-prefixed album is listed")
        XCTAssertEqual(album.storageOption, .local)
        XCTAssertEqual(albumManager.albumMediaCount(album: album), 1, "its media is found")
    }

    /// A pre-encryption album's directory name is whatever the user typed, dots
    /// included. Excluding every dotted name to keep SDK caches out made these
    /// albums vanish from the grid with their files intact.
    func testDiscoversPlaintextAlbumNamesContainingDots() throws {
        try seedDirectory("Trip 2.0", at: root)
        try seedDirectory("Nov. 2023", at: root)

        XCTAssertEqual(discoveredNames(), ["Trip 2.0", "Nov. 2023"])
    }

    /// The other side of the dotted-name rule: a reverse-DNS SDK cache that is
    /// not RevenueCat's has no reserved substring to catch it, so its shape alone
    /// must keep it out of the grid.
    func testExcludesReverseDNSDirectoriesThatAreNotRevenueCat() throws {
        try seedDirectory("com.apple.CloudDocs", at: root)
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["met"])
    }

    // MARK: - Naming rule permutations
    //
    // Album names went unvalidated for years, so a pre-encryption album
    // directory can be named with anything a keyboard produces. These
    // drive `isAlbumDirectoryName` directly: the discovery tests above prove the
    // rule is wired in; these prove the rule itself.

    private func assertAlbums(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        for name in names {
            XCTAssertTrue(AlbumDirectoryNaming.isAlbumDirectoryName(name),
                          "\(name.debugDescription) should be an album", file: file, line: line)
        }
    }

    private func assertNotAlbums(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        for name in names {
            XCTAssertFalse(AlbumDirectoryNaming.isAlbumDirectoryName(name),
                           "\(name.debugDescription) should not be an album", file: file, line: line)
        }
    }

    func testNamingRuleAcceptsUserTypedShapes() {
        assertAlbums([
            "Trip.",                // trailing dot
            "Trip..2",              // empty component
            "com.apple",            // two components is not reverse-DNS
            "Trip\u{00A0}2.0.1",    // non-breaking space
            "Summer 100%",
            "Q&A #1?",
            "Trip: Rome",
            "Revenue Catalog",      // not the "revenuecat" substring
            "Album_abc+def==",      // encrypted-name alphabet
        ])
    }

    func testNamingRuleExcludesReverseDNSAndBookkeepingShapes() {
        assertNotAlbums([
            "com.apple.CloudDocs",
            "me.freas.encamera.revenuecat.etags",
            "com.google.firebase_crashlytics",   // underscore label
            "com.crashlytics.data-v2",           // hyphen label
            ".Trash",
            ".com.apple.bookkeeping",
            "RevenueCat",
            "REVENUECAT_cache",
            "Albums",
            "INBOX",
        ])
    }

    /// Bundle identifiers are ASCII. A dotted name with letters outside ASCII
    /// cannot be an SDK cache, whatever its component count.
    func testNamingRuleTreatsNonASCIIDottedNamesAsAlbums() {
        assertAlbums([
            "日本.旅行.2023",
            "Trip.to.París",
            "Ünen.mit.Ömer",
        ])
    }

    /// A reverse-DNS name starts with a top-level domain, which is letters.
    /// A name whose first label is numeric is a version, a date, or a score.
    func testNamingRuleTreatsVersionLikeNamesAsAlbums() {
        assertAlbums([
            "1.2.3",
            "2023.11.05",
            "v1.2.3",
            "3.14.15.92",
        ])
    }

    /// Bundle identifiers are written with a lowercase top-level domain. A
    /// capitalized first label is a person, a title, or a sentence.
    func testNamingRuleTreatsCapitalizedDottedNamesAsAlbums() {
        assertAlbums([
            "Mr.Mrs.Smith",
            "Dr.J.Smith",
            "Trip.To.Paris",
        ])
    }

    /// A leading dot was typeable too, and the rule that predates `albums/`
    /// showed those albums. Only `.Trash` and dot-prefixed bundle identifiers
    /// are bookkeeping.
    func testNamingRuleTreatsDotPrefixedUserNamesAsAlbums() {
        assertAlbums([
            ".secret",
            ".2023",
            ".Trip 2.0",
        ])
        assertNotAlbums([
            ".Trash",
            ".trash",
            ".com.apple.bookkeeping",
        ])
    }

    /// Only a name that starts with a top-level domain SDKs actually publish
    /// under is a cache. Three lowercase words with dots between them is a
    /// name.
    func testNamingRuleOnlyExcludesKnownTopLevelDomains() {
        assertAlbums([
            "photos.from.rome",
            "trip.to.paris",
            "www.example.photos",
        ])
        assertNotAlbums([
            "me.freas.encamera.revenuecat.etags",
            "com.apple.CloudDocs",
            "net.example.cache",
            "org.example.cache",
            "io.example.cache",
        ])
    }

    /// A root copy left behind by a failed move must not double the album in the
    /// grid — the migrated copy under `albums/` wins.
    func testDeduplicatesAnAlbumPresentInBothLayouts() throws {
        let albums = try seedAlbumsSubdirectory()
        try seedDirectory("met", at: albums)
        try seedDirectory("met", at: root)

        let discovered = ScratchStorageModel.enumerateAlbumsDirectory()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.deletingLastPathComponent().standardizedFileURL,
                       albums.standardizedFileURL)
    }

    // MARK: - iCloud Drive account without a container

    /// A device with an iCloud account but a nil ubiquity container URL used to
    /// crash here (`iCloudStorageModel.rootURL` trapped), on every launch, because
    /// `AlbumManager.init` lists albums straight after unlock. Falling back to the
    /// local Documents directory instead would list every root-level legacy local
    /// album a second time as iCloud Drive, so that layout is seeded too.
    func testFetchAlbumsFromSourcesSurvivesANilContainerWithAToken() throws {
        let savedSource = iCloudStorageModel.containerSource
        let savedOverride = iCloudStorageModel.testContainerRootOverride
        var seeded: [URL] = []
        defer {
            iCloudStorageModel.containerSource = savedSource
            iCloudStorageModel.testContainerRootOverride = savedOverride
            seeded.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        iCloudStorageModel.testContainerRootOverride = nil
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { true },
                                                   containerURL: { nil })

        let key = PrivateKey(name: AppConstants.defaultKeyName,
                             keyBytes: Array(repeating: 0x7E, count: 32),
                             creationDate: Date())
        let suffix = UUID().uuidString.prefix(8)
        let migrated = Album(name: "NoContainer-albums-\(suffix)", storageOption: .local,
                             creationDate: Date(), key: key)
        let legacy = Album(name: "NoContainer-root-\(suffix)", storageOption: .local,
                           creationDate: Date(), key: key)
        for (album, parent) in [(migrated, LocalStorageModel.albumsURL), (legacy, LocalStorageModel.rootURL)] {
            let url = parent.appendingPathComponent(album.encryptedPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            seeded.append(url)
        }

        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let albums = AlbumManager(keyManager: keyManager).fetchAlbumsFromSources(includingHidden: true)

        for name in [migrated.name, legacy.name] {
            let matches = albums.filter { $0.name == name }
            XCTAssertEqual(matches.count, 1, "\(name) must be listed exactly once")
            XCTAssertEqual(matches.first?.storageOption, .local)
        }
        XCTAssertFalse(albums.contains { $0.storageOption == .icloud })
    }

    /// A move back to this device creates the local album's directory at the start
    /// of the run. Until finalize the album is the CloudKit one, so the list shows
    /// only that, or a user could delete the "duplicate" mid-move. The real
    /// `AlbumManager` listing is used, with the album's real directories.
    @MainActor
    func testFetchAlbumsFromSourcesHidesTheToLocalTwinWhileItsPlanExists() async throws {
        let key = PrivateKey(name: "key", keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) },
                             creationDate: Date())
        let albumID = UUID().uuidString
        let cloudAlbum = Album(name: "twin-\(UUID().uuidString)", storageOption: .cloudKit,
                               creationDate: Date(), key: key, albumID: albumID)
        let twin = Album.localTwin(of: cloudAlbum)
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        defer {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            try? FileManager.default.removeItem(at: LocalStorageModel(album: twin).baseURL)
            try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: cloudAlbum))
        }
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: false).write(albumID: albumID)
        try LocalStorageModel(album: twin).initializeDirectories()
        let planStore = MigrationPlanStore(album: cloudAlbum)
        try await planStore.save(try MigrationPlan.album(cloudAlbum, items: []))
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: twin.id), .destination(.toLocal, isRunning: false),
                       "precondition: the plan names the local album as its destination")

        let listedIDs = { Set(albumManager.fetchAlbumsFromSources(includingHidden: true).map(\.id)) }
        XCTAssertTrue(listedIDs().contains(cloudAlbum.id), "the CloudKit album stays listed")
        XCTAssertFalse(listedIDs().contains(twin.id), "the twin a move back is filling is not listed")
        XCTAssertFalse(albumManager.fetchAlbumsFromSources().contains { $0.id == twin.id })
        XCTAssertFalse(albumManager.hasFinishedMoving(album: cloudAlbum),
                       "hiding the twin does not make the source read as moved")
        XCTAssertFalse(albumManager.hasFinishedMoving(album: twin))

        // Finalize removes the CloudKit album before the plan: the local album shows
        // at once, so the album never drops out of the list.
        try CloudKitAlbumMarker.remove(albumID: albumID)
        XCTAssertTrue(listedIDs().contains(twin.id), "with the CloudKit album gone, the local album is the album")
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: false).write(albumID: albumID)

        // Without a plan, a same-named local album is an album in its own right.
        await planStore.delete()
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: twin.id), .none)
        XCTAssertTrue(listedIDs().isSuperset(of: [cloudAlbum.id, twin.id]))
    }
}
