//
//  RequestedUpgradesStoreTests.swift
//  EncameraCoreTests
//
//  The stored list of albums the user asked to upgrade: its round trip, what
//  an unreadable file reads as, the version 1 format on disk and its removal.
//

import XCTest
@testable import EncameraCore

final class RequestedUpgradesStoreTests: XCTestCase {

    private var directory: URL!
    private var store: RequestedUpgradesStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("requested-upgrades-\(UUID().uuidString)", isDirectory: true)
        store = RequestedUpgradesStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeFile(_ contents: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: store.fileURL)
    }

    /// The committed version 1 file as shipped in the test bundle. The
    /// app-hosted Xcode target flattens it to the bundle root; `swift test`
    /// processes it into the test target's `Bundle.module`.
    private func bundledFixtureURL() throws -> URL {
        let name = "requested-upgrades-v1"
        let testBundle = Bundle(for: Self.self)
        let candidates = [
            testBundle.url(forResource: name, withExtension: "json"),
            testBundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: "json")
        ]
        return try XCTUnwrap(candidates.compactMap { $0 }.first, "Missing fixture \(name).json in the test bundle")
    }

    func testSavedOrderIsLoadedBack() throws {
        let albumIDs = [UUID().uuidString, UUID().uuidString, UUID().uuidString]

        try store.saveAlbumIDs(albumIDs)

        XCTAssertEqual(store.loadAlbumIDs(), albumIDs, "in the order they were asked for")
        XCTAssertEqual(RequestedUpgradesStore(directory: directory).loadAlbumIDs(), albumIDs, "another store over the directory reads the same")

        try store.saveAlbumIDs([albumIDs[2]])
        XCTAssertEqual(store.loadAlbumIDs(), [albumIDs[2]], "a save replaces the list")
        try store.saveAlbumIDs([])
        XCTAssertEqual(store.loadAlbumIDs(), [])
    }

    func testFileIsNamedRequestedUpgradesInTheGivenDirectory() {
        XCTAssertEqual(store.fileURL, directory.appendingPathComponent("requested-upgrades.json"))
        XCTAssertEqual(RequestedUpgradesStore().fileURL,
                       MigrationPlanFileUtil.iCloudDriveAlbumsDirectory.appendingPathComponent("requested-upgrades.json"),
                       "beside the per-album plan directories by default")
    }

    func testSavedFileHoldsTheVersionAndAlbumIDsOnly() throws {
        let albumIDs = [UUID().uuidString, UUID().uuidString]

        try store.saveAlbumIDs(albumIDs)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "albumIDs"], "no name, path or key material")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["albumIDs"] as? [String], albumIDs)
    }

    func testSaveLeavesNoTemporaryFileBesideTheList() throws {
        try store.saveAlbumIDs([UUID().uuidString])
        try store.saveAlbumIDs([UUID().uuidString])

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["requested-upgrades.json"])
    }

    func testMissingFileLoadsAsEmpty() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "precondition: not even the directory exists")

        XCTAssertEqual(store.loadAlbumIDs(), [])
    }

    func testCorruptFileLoadsAsEmpty() throws {
        for contents in ["", "not json", "{\"version\":1,\"albumIDs\":", "[\"a\"]", "{\"version\":1}", "{\"version\":\"1\",\"albumIDs\":[]}",
                         "{\"version\":1,\"albumIDs\":[1,2]}"] {
            try writeFile(contents)

            XCTAssertEqual(store.loadAlbumIDs(), [], "\(contents)")
        }
    }

    func testUnknownVersionLoadsAsEmpty() throws {
        for version in [0, 2, 99] {
            try writeFile("{\"version\":\(version),\"albumIDs\":[\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\"]}")

            XCTAssertEqual(store.loadAlbumIDs(), [], "version \(version)")
        }
    }

    /// Decodes the committed fixture, a version 1 file as devices hold it. The
    /// fixture must never be regenerated from this code to make a failing test
    /// pass: a failure means a change broke reading existing files, and the
    /// change is what to revert.
    func testVersionOneGoldenFileDecodes() throws {
        let fixture = try bundledFixtureURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: store.fileURL)

        XCTAssertEqual(store.loadAlbumIDs(), ["3F2504E0-4F89-41D3-9A0C-0305E82C3301",
                                              "9B2C1A7E-5D0F-4E3A-8C61-2F4D7A9E0B15",
                                              "0E7A5C12-88B4-4F6D-B3E9-6C1D2A4F7E90"])
    }

    func testVersionOneFileWithAFieldALaterBuildAddedStillDecodes() throws {
        try writeFile("{\"version\":1,\"albumIDs\":[\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\"],\"later\":true}")

        XCTAssertEqual(store.loadAlbumIDs(), ["3F2504E0-4F89-41D3-9A0C-0305E82C3301"])
    }

    func testRemoveDeletesTheFile() throws {
        try store.saveAlbumIDs([UUID().uuidString])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        try store.removeFile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.loadAlbumIDs(), [])
        XCTAssertNoThrow(try store.removeFile(), "removing a file that is not there is not an error")
    }
}
