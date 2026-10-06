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
}
