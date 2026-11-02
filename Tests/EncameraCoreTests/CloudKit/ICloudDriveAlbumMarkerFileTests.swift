//
//  ICloudDriveAlbumMarkerFileTests.swift
//  EncameraCoreTests
//
//  The marker file that links an iCloud Drive album folder to its CloudKit album:
//  its on-disk format, and how each state of the file in a folder reads.
//

import XCTest
@testable import EncameraCore

final class ICloudDriveAlbumMarkerFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudDriveAlbumMarkerFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private var markerURL: URL {
        ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: directory)
    }

    private func noConflicts(_ url: URL) -> [URL] { [] }

    /// Writes `object` as JSON into a scratch file outside the album folder.
    private func writeJSON(_ object: [String: Any], named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudDriveAlbumMarkerFileTests-\(UUID().uuidString)-\(name)")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The committed fixture as shipped in the test bundle. The app-hosted Xcode
    /// target flattens it to the bundle root; `swift test` processes it into the
    /// test target's `Bundle.module`.
    private func bundledFixtureURL() throws -> URL {
        let name = "icloud-drive-album-marker-v1"
        let testBundle = Bundle(for: Self.self)
        let candidates = [
            testBundle.url(forResource: name, withExtension: "json"),
            testBundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: "json")
        ]
        return try XCTUnwrap(candidates.compactMap { $0 }.first, "Missing fixture \(name).json in the test bundle")
    }

    func testRoundTripKeepsOnlyAlbumIDAndVersion() throws {
        let albumID = UUID().uuidString
        let marker = ICloudDriveAlbumMarkerFile(albumID: albumID)

        try marker.write(toAlbumDirectory: directory)

        XCTAssertEqual(markerURL.lastPathComponent, ICloudDriveAlbumMarkerFile.fileName)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["albumID", "formatVersion"], "no other fields are written")
        XCTAssertEqual(object["albumID"] as? String, albumID)
        XCTAssertEqual(object["formatVersion"] as? Int, ICloudDriveAlbumMarkerFile.currentFormatVersion)

        let read = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts)
        XCTAssertEqual(read, .present(ICloudDriveAlbumMarkerFile(albumID: albumID, formatVersion: 1)))

        let replacement = ICloudDriveAlbumMarkerFile(albumID: UUID().uuidString)
        try replacement.write(toAlbumDirectory: directory)
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .present(replacement), "a second write replaces the first")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [ICloudDriveAlbumMarkerFile.fileName], "the write leaves no scratch file behind")
    }

    /// Pins the format every build must read. The fixture was written by hand, not
    /// by this code; if it stops decoding, revert the change rather than the fixture.
    func testGoldenMarkerFileDecodes() throws {
        let data = try Data(contentsOf: bundledFixtureURL())

        let decoded = try XCTUnwrap(ICloudDriveAlbumMarkerFile.decode(data))
        XCTAssertEqual(decoded.albumID, "3F2504E0-4F89-41D3-9A0C-0305E82C3301")
        XCTAssertEqual(decoded.formatVersion, 1)

        try data.write(to: markerURL)
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .present(decoded))
    }

    func testEvictedPlaceholderReadsAsEvicted() throws {
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .absent, "an empty folder has no marker")

        let placeholder = ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: placeholder.path, contents: Data([0x62, 0x70])))

        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .evicted, "only the placeholder brick is on disk")
    }

    /// iOS can keep an evicted file at its own path; only the download status says
    /// the bytes are not here.
    func testEvictedInPlaceReadsAsEvicted() throws {
        try ICloudDriveAlbumMarkerFile(albumID: UUID().uuidString).write(toAlbumDirectory: directory)
        ICloudPlaceholderName.testEvictedURLs = [markerURL.standardizedFileURL]
        defer { ICloudPlaceholderName.testEvictedURLs = nil }

        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .evicted)
    }

    func testUnknownFormatVersionReadsAsUnreadable() throws {
        let newer = try writeJSON(["albumID": UUID().uuidString,
                                   "formatVersion": ICloudDriveAlbumMarkerFile.currentFormatVersion + 1,
                                   "somethingNew": true],
                                  named: "newer.json")
        try FileManager.default.copyItem(at: newer, to: markerURL)

        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .unreadable)

        try FileManager.default.removeItem(at: markerURL)
        try Data("not json".utf8).write(to: markerURL)
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory, conflictVersions: noConflicts),
                       .unreadable, "damaged bytes are unreadable, not absent")
    }

    func testConflictVersionsReadAsConflicted() throws {
        let current = ICloudDriveAlbumMarkerFile(albumID: UUID().uuidString)
        try current.write(toAlbumDirectory: directory)
        let otherAlbumID = UUID().uuidString
        let conflictURL = try writeJSON(["albumID": otherAlbumID, "formatVersion": 1], named: "conflict.json")

        var lookedUp: [URL] = []
        let read = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory) { url in
            lookedUp.append(url)
            return [conflictURL]
        }

        XCTAssertEqual(read, .conflicted([current, ICloudDriveAlbumMarkerFile(albumID: otherAlbumID)]))
        XCTAssertEqual(lookedUp.map(\.standardizedFileURL), [markerURL.standardizedFileURL],
                       "conflict versions are looked up for the marker file itself")

        let unreadableConflict = try writeJSON(["albumID": otherAlbumID, "formatVersion": 99], named: "newer.json")
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: directory) { _ in [conflictURL, unreadableConflict] },
                       .unreadable, "a conflict version this build cannot read leaves the marker unreadable")
    }
}
