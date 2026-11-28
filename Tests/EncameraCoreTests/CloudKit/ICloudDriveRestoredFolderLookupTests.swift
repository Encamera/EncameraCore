//
//  ICloudDriveRestoredFolderLookupTests.swift
//  EncameraCoreTests
//
//  The lookup of the iCloud Drive folder a CloudKit album's migration would
//  move from, and whether it holds media. The iCloud Drive container is a
//  scratch directory; the CloudKit album is a real `album.json`.
//

import XCTest
@testable import EncameraCore

/// Records whether each marker read ran on the main thread.
private final class MarkerReadThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []

    func record() {
        lock.lock()
        defer { lock.unlock() }
        onMain.append(Thread.isMainThread)
    }

    var reads: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return onMain
    }
}

@MainActor
final class ICloudDriveRestoredFolderLookupTests: XCTestCase {

    private var containerRoot: URL!
    private var key: PrivateKey!
    private var markerCache: ICloudDriveFolderMarkerCache!
    private var markerReads: MarkerReadThreads!
    private var touchedAlbumIDs: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("icloud-restored-folder-lookup-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot
        try FileManager.default.createDirectory(at: iCloudStorageModel.albumsURL, withIntermediateDirectories: true)
        key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let reads = MarkerReadThreads()
        markerReads = reads
        markerCache = ICloudDriveFolderMarkerCache(readMarker: { folder in
            reads.record()
            return ICloudDriveFolderMarkerCache.Reading(
                marker: ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder, conflictVersions: { _ in [] }),
                folderPath: CloudKitAlbumMarker.iCloudDriveFolderPath(for: folder))
        })
    }

    override func tearDownWithError() throws {
        for albumID in touchedAlbumIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        touchedAlbumIDs = []
        iCloudStorageModel.testContainerRootOverride = nil
        ICloudPlaceholderName.testEvictedURLs = nil
        try? FileManager.default.removeItem(at: containerRoot)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A CloudKit album named `name` under the test key, with its `album.json`
    /// written, optionally linked to `linkedFolder`.
    private func makeCloudKitAlbum(named name: String = "Holiday", linkedFolder: URL? = nil) throws -> Album {
        let albumID = UUID().uuidString
        touchedAlbumIDs.insert(albumID)
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key, albumID: albumID)
        var marker = CloudKitAlbumMarker(album: album, isHidden: false)
        if let linkedFolder {
            XCTAssertTrue(marker.linkICloudDriveFolder(linkedFolder), "precondition: the folder is in the container")
        }
        try marker.write(albumID: albumID)
        return album
    }

    /// An iCloud Drive album folder named `name`'s ciphertext under the test key.
    private func makeFolder(named name: String = "Holiday") throws -> URL {
        let folderName = Album(name: name, storageOption: .icloud, creationDate: Date(), key: key).encryptedPathComponent
        let folder = iCloudStorageModel.albumsURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeMarker(naming albumID: String, in folder: URL) throws {
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: folder)
    }

    @discardableResult
    private func addPhoto(to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).\(MediaType.photo.encryptedFileExtension)")
        try Data("ciphertext".utf8).write(to: url)
        return url
    }

    private func lookUp(_ album: Album,
                        deletedAlbumIDs: Set<String> = [],
                        hasICloudDrive: @escaping () -> Bool = { true }) async -> URL? {
        await ICloudDriveRestoredFolderLookup.folderHoldingMedia(for: album,
                                                                 albumFolders: ICloudDriveAlbumFolderWalk.albumFolders(),
                                                                 deletedAlbumIDs: deletedAlbumIDs,
                                                                 markerCache: markerCache,
                                                                 hasICloudDrive: hasICloudDrive)
    }

    private func assertSameFolder(_ found: URL?, _ expected: URL,
                                  _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found?.standardizedFileURL.resolvingSymlinksInPath().path,
                       expected.standardizedFileURL.resolvingSymlinksInPath().path, message, file: file, line: line)
    }

    // MARK: - Folders that match

    func testFindsLinkedFolderHoldingMedia() async throws {
        let folder = try makeFolder(named: "Renamed since")
        let album = try makeCloudKitAlbum(named: "Holiday", linkedFolder: folder)
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)
        try addPhoto(to: folder)

        let found = await lookUp(album)

        assertSameFolder(found, folder, "the folder album.json links is the album's, whatever its name")
    }

    func testFindsUnlinkedFolderWhoseMarkerNamesTheAlbum() async throws {
        let album = try makeCloudKitAlbum()
        let folder = try makeFolder(named: "Another name")
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)
        try addPhoto(to: folder)

        let found = await lookUp(album)

        assertSameFolder(found, folder, "a folder whose marker names the album is the album's")
    }

    func testFindsMarkerlessFolderWithTheAlbumsNameAndKey() async throws {
        let album = try makeCloudKitAlbum(named: "Holiday")
        let folder = try makeFolder(named: "Holiday")
        try addPhoto(to: folder)

        let found = await lookUp(album)

        assertSameFolder(found, folder, "a marker-less folder with the album's name under its key is the album's")
    }

    func testLinkedFolderWinsOverMarkerNamedFolder() async throws {
        let linked = try makeFolder(named: "Linked")
        let album = try makeCloudKitAlbum(named: "Holiday", linkedFolder: linked)
        let albumID = try XCTUnwrap(album.albumID)
        try writeMarker(naming: albumID, in: linked)
        try addPhoto(to: linked)
        let named = try makeFolder(named: "Restored")
        try writeMarker(naming: albumID, in: named)
        try addPhoto(to: named)

        let found = await lookUp(album)

        assertSameFolder(found, linked, "the linked folder is tried first")
    }

    func testCountsAnEvictedPlaceholderAsMedia() async throws {
        let album = try makeCloudKitAlbum()
        let folder = try makeFolder(named: "Restored")
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)
        let materialized = folder.appendingPathComponent("\(UUID().uuidString).\(MediaType.photo.encryptedFileExtension)")
        try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: materialized))
        ICloudPlaceholderName.testEvictedURLs = [materialized.standardizedFileURL]

        let found = await lookUp(album)

        assertSameFolder(found, folder, "a file only its iCloud placeholder stands for is media")
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.path), "nothing was downloaded")
    }

    // MARK: - Folders that do not match

    func testIgnoresMarkerlessFolderWithAnotherName() async throws {
        let album = try makeCloudKitAlbum(named: "Holiday")
        let folder = try makeFolder(named: "Birthday")
        try addPhoto(to: folder)

        let found = await lookUp(album)

        XCTAssertNil(found, "a marker-less folder with another name belongs to another album")
    }

    func testIgnoresFolderWhoseMarkerNamesAnotherAlbum() async throws {
        let album = try makeCloudKitAlbum(named: "Holiday")
        let folder = try makeFolder(named: "Holiday")
        try writeMarker(naming: UUID().uuidString, in: folder)
        try addPhoto(to: folder)

        let found = await lookUp(album)

        XCTAssertNil(found, "a marker naming another album wins over the folder's name")
    }

    func testIgnoresFolderWhoseMarkerNamesADeletedAlbum() async throws {
        let album = try makeCloudKitAlbum()
        let albumID = try XCTUnwrap(album.albumID)
        let folder = try makeFolder(named: "Restored")
        try writeMarker(naming: albumID, in: folder)
        try addPhoto(to: folder)

        let found = await lookUp(album, deletedAlbumIDs: [albumID])

        XCTAssertNil(found, "a folder of an album deleted here is what is left of it")
    }

    func testIgnoresFolderHoldingOnlyTheMarker() async throws {
        let album = try makeCloudKitAlbum()
        let folder = try makeFolder(named: "Restored")
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)

        let found = await lookUp(album)

        XCTAssertNil(found, "a folder holding only the marker has nothing to migrate")
    }

    func testIgnoresEmptyFolders() async throws {
        let linked = try makeFolder(named: "Linked")
        let album = try makeCloudKitAlbum(named: "Holiday", linkedFolder: linked)
        _ = try makeFolder(named: "Holiday")

        let found = await lookUp(album)

        XCTAssertNil(found, "neither an empty linked folder nor an empty same-named folder holds media")
    }

    func testIgnoresFolderWhoseMarkerIsEvicted() async throws {
        let album = try makeCloudKitAlbum(named: "Holiday")
        let folder = try makeFolder(named: "Holiday")
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder)
        try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL))
        try addPhoto(to: folder)

        let found = await lookUp(album)

        XCTAssertNil(found, "an evicted marker may name another album")
    }

    func testReturnsNilWithoutICloudDrive() async throws {
        let album = try makeCloudKitAlbum()
        let folder = try makeFolder(named: "Restored")
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)
        try addPhoto(to: folder)

        let found = await lookUp(album, hasICloudDrive: { false })

        XCTAssertNil(found)
        XCTAssertTrue(markerReads.reads.isEmpty, "no marker is read without iCloud Drive")
    }

    // MARK: - Side effects

    func testReadsMarkersOffTheMainThread() async throws {
        let album = try makeCloudKitAlbum()
        let folder = try makeFolder(named: "Restored")
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)
        try addPhoto(to: folder)

        let found = await lookUp(album)

        assertSameFolder(found, folder, "precondition: the folder is found")
        XCTAssertFalse(markerReads.reads.isEmpty, "precondition: markers were read")
        XCTAssertFalse(markerReads.reads.contains(true), "a main-actor caller is never blocked on a marker read")
    }

    func testWritesNothing() async throws {
        let linked = try makeFolder(named: "Linked")
        let album = try makeCloudKitAlbum(named: "Holiday", linkedFolder: linked)
        let albumID = try XCTUnwrap(album.albumID)
        try writeMarker(naming: UUID().uuidString, in: linked)
        try addPhoto(to: linked)
        let restored = try makeFolder(named: "Restored")
        try writeMarker(naming: albumID, in: restored)
        try addPhoto(to: restored)
        let sameName = try makeFolder(named: "Holiday")
        try addPhoto(to: sameName)
        let watched = [containerRoot!,
                       CloudKitAlbumMarker.directoryURL(albumID: albumID),
                       MediaIndexStore.indexDirectoryURL(),
                       MigrationPlanFileUtil.rootDirectory]
        let before = watched.map(snapshot(of:))

        let found = await lookUp(album)

        assertSameFolder(found, restored, "precondition: the lookup ran to a folder")
        XCTAssertEqual(watched.map(snapshot(of:)), before,
                       "the folders, album.json, the index and the plans are untouched")
    }

    func testConvenienceFindsTheFolderThroughTheAlbumManager() async throws {
        let album = try makeCloudKitAlbum()
        let folder = try makeFolder(named: "Restored")
        try writeMarker(naming: try XCTUnwrap(album.albumID), in: folder)
        try addPhoto(to: folder)
        let albumManager = AlbumManager(keyManager: DemoKeyManager(keys: [key]), syncedDataStore: nil)
        albumManager.iCloudDriveFolderMarkers = markerCache

        let found = await ICloudDriveRestoredFolderLookup.folderHoldingMedia(for: album, albumManager: albumManager)

        assertSameFolder(found, folder, "the convenience lists the container's folders itself")
    }

    /// Every file under `directory` by relative path, with its bytes.
    private func snapshot(of directory: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return files
        }
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = String(path.dropFirst(base.count))
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            files[relative] = isDirectory.boolValue ? Data() : (try? Data(contentsOf: url)) ?? Data()
        }
        return files
    }
}
