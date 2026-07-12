//
//  ReconcileMetadataUpdatesTests.swift
//  EncameraCoreTests
//
//  Regression coverage for the in-place modification path of
//  `reconcileIndex`. The original implementation only handled added /
//  removed ids, so edits that rewrote a file but kept its id left the
//  cached sort and filter keys stale. The fix detects modifications via
//  `idsModifiedSince` and re-reads metadata for those ids — this test
//  pins the detection helper.
//

import XCTest
@testable import EncameraCore

final class ReconcileMetadataUpdatesTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconcileMetadataUpdatesTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sets the file's modification date to `date`. Goes through
    /// `FileManager` so it works the same way `enumeratorForStorageDirectory`
    /// reads it back.
    private func setModificationDate(_ date: Date, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    /// A file modified strictly after the reference date is detected.
    func testFileModifiedAfterReferenceIsFlagged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        let url = dir.appendingPathComponent("\(id).encimage")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))

        let reference = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try setModificationDate(reference.addingTimeInterval(60), on: url)

        let modified = DiskMediaBackend.idsModifiedSince(
            reference,
            among: [id],
            urlsByID: [id: [url]]
        )
        XCTAssertEqual(modified, [id])
    }

    /// A file whose mtime is at or before the reference is left alone.
    /// `idsModifiedSince` uses a strict `>` so equal timestamps don't
    /// trigger an unnecessary re-read.
    func testFileNotModifiedSinceReferenceIsNotFlagged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        let url = dir.appendingPathComponent("\(id).encimage")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))

        let reference = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try setModificationDate(reference.addingTimeInterval(-60), on: url)

        let modified = DiskMediaBackend.idsModifiedSince(
            reference,
            among: [id],
            urlsByID: [id: [url]]
        )
        XCTAssertTrue(modified.isEmpty)
    }

    /// Live photos have a photo and a video component sharing one id. If
    /// either component was rewritten since the reference, the id must be
    /// flagged so the metadata is re-read.
    func testLivePhotoIsFlaggedWhenEitherComponentIsModified() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID().uuidString
        let photo = dir.appendingPathComponent("\(id).encimage")
        let video = dir.appendingPathComponent("\(id).encvideo")
        XCTAssertTrue(FileManager.default.createFile(atPath: photo.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: video.path, contents: Data()))

        let reference = Date(timeIntervalSinceReferenceDate: 700_000_000)
        // Photo is untouched, video was rewritten after the reference.
        try setModificationDate(reference.addingTimeInterval(-60), on: photo)
        try setModificationDate(reference.addingTimeInterval(60), on: video)

        let modified = DiskMediaBackend.idsModifiedSince(
            reference,
            among: [id],
            urlsByID: [id: [photo, video]]
        )
        XCTAssertEqual(modified, [id],
                       "When a live photo's video component is rewritten in place, the id "
                       + "must be flagged so reconcile re-reads the metadata.")
    }

    /// An id whose URLs aren't in the map (e.g. file was removed since the
    /// scan) is simply skipped — that branch belongs to the `removedIDs`
    /// path, not this one.
    func testIDWithNoURLsIsIgnored() {
        let modified = DiskMediaBackend.idsModifiedSince(
            Date(timeIntervalSinceReferenceDate: 700_000_000),
            among: ["ghost-id"],
            urlsByID: [:]
        )
        XCTAssertTrue(modified.isEmpty)
    }
}
