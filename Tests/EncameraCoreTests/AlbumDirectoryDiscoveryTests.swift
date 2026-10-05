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

    func testExcludesFilesAndDotDirectories() throws {
        try seedDirectory(".Trash", at: root)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent("loose.encimage").path, contents: Data()))
        try seedDirectory("met", at: root)

        XCTAssertEqual(discoveredNames(), ["met"])
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
