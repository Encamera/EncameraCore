//
//  AlbumRemoveDrainedSourceDirectoryTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class AlbumRemoveDrainedSourceDirectoryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumRemoveDrainedSourceDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A drained album directory with only empty subdirectories left in it.
    private func makeDrainedDirectory() throws -> URL {
        let album = root.appendingPathComponent("Album_drained", isDirectory: true)
        try FileManager.default.createDirectory(at: album.appendingPathComponent("thumbs", isDirectory: true),
                                                withIntermediateDirectories: true)
        return album
    }

    /// Another device's file lands after the first check finds the directory empty;
    /// the check inside the coordinated delete must see it and keep the directory.
    func testKeepsADirectoryThatGainsAFileBeforeTheCoordinatedDelete() throws {
        let album = try makeDrainedDirectory()
        let lateFile = album.appendingPathComponent("late-capture.encimage")
        var hookRan = false

        let removed = Album.removeDrainedSourceDirectory(at: album) {
            hookRan = true
            FileManager.default.createFile(atPath: lateFile.path, contents: Data("ciphertext".utf8))
        }

        XCTAssertTrue(hookRan, "The first check found no files, so the coordinated delete must be reached")
        XCTAssertFalse(removed, "A directory that gained a file before the delete must be reported as kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateFile.path),
                      "The file that arrived before the coordinated delete must survive")
    }

    func testRemovesAnEmptyDrainedDirectory() throws {
        let album = try makeDrainedDirectory()

        let removed = Album.removeDrainedSourceDirectory(at: album)

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path),
                       "A drained directory with no regular files must be deleted")
    }

    // MARK: - Which folders count as drained

    /// An iCloud Drive album folder under a scratch container, holding one media
    /// file, and the CloudKit album with its name and key on this device. The
    /// CloudKit album links the folder when `linked`.
    private func makeMovedICloudDriveAlbum(linked: Bool) throws -> (model: iCloudStorageModel, albumID: String) {
        iCloudStorageModel.testContainerRootOverride = root.appendingPathComponent("container", isDirectory: true)
        let key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let album = Album(name: "trip-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: key)
        let model = iCloudStorageModel(album: album)
        try FileManager.default.createDirectory(at: model.baseURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: model.baseURL.appendingPathComponent("\(UUID().uuidString).encimage").path,
                                       contents: Data("ciphertext".utf8))
        let albumID = UUID().uuidString
        albumIDs.append(albumID)
        var marker = CloudKitAlbumMarker(album: Album.cloudKitTwin(of: album, albumID: albumID), isHidden: false)
        if linked {
            XCTAssertTrue(marker.linkICloudDriveFolder(model.baseURL))
        }
        try marker.write(albumID: albumID)
        return (model, albumID)
    }

    private var albumIDs: [String] = []

    override func tearDown() {
        for albumID in albumIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        albumIDs = []
        iCloudStorageModel.testContainerRootOverride = nil
        super.tearDown()
    }

    /// A folder its CloudKit album links holds that album's media not yet in
    /// CloudKit: it is left alone, but nothing treats it as drained, and the
    /// drained-directory removal keeps it.
    func testLinkedFolderWithMediaIsNotTreatedAsDrained() throws {
        let (model, _) = try makeMovedICloudDriveAlbum(linked: true)

        XCTAssertTrue(model.isLinkedICloudDriveFolder)
        XCTAssertTrue(model.hasMigratedToCloudKit, "not re-created")
        XCTAssertFalse(model.isDrainedICloudDriveSource)
        XCTAssertFalse(model.isDrainedSourceOfCloudKitMove)

        XCTAssertFalse(Album.removeDrainedSourceDirectory(at: model.baseURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.baseURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: model.baseURL.path).count, 1)
    }

    /// A whole-album move's source, which its CloudKit album does not link, is
    /// still the drained source it always was: an iCloud Drive folder whose
    /// CloudKit album matches its name and key is not re-created once gone, and a
    /// local album's drained directory is recognised as before.
    func testLocalToCloudKitDrainedSourceBehaviorUnchanged() throws {
        let (model, _) = try makeMovedICloudDriveAlbum(linked: false)

        XCTAssertFalse(model.isLinkedICloudDriveFolder)
        XCTAssertTrue(model.isDrainedICloudDriveSource)
        XCTAssertTrue(model.hasMigratedToCloudKit)
        XCTAssertFalse(model.isDrainedSourceOfCloudKitMove, "an iCloud Drive folder is never the local drained source")

        try FileManager.default.removeItem(at: model.baseURL)
        try model.initializeDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.baseURL.path), "the drained source is not re-created")

        // A local album whose move to CloudKit finished.
        let key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let local = Album(name: "local-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
        let localModel = LocalStorageModel(album: local)
        XCTAssertFalse(localModel.isDrainedSourceOfCloudKitMove, "no CloudKit album yet")
        let albumID = UUID().uuidString
        albumIDs.append(albumID)
        try CloudKitAlbumMarker(album: Album.cloudKitTwin(of: local, albumID: albumID), isHidden: false).write(albumID: albumID)
        XCTAssertTrue(localModel.isDrainedSourceOfCloudKitMove)
        XCTAssertFalse(localModel.hasMigratedToCloudKit, "only an iCloud Drive folder")
    }
}
