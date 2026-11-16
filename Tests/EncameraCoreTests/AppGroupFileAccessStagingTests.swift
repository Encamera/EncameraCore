//
//  AppGroupFileAccessStagingTests.swift
//  EncameraCoreTests
//
//  Shared media waits in the App Group for at most a day. Its age is the time
//  it was staged, recorded as the file's modification date, because a copied
//  file keeps the source's dates and a photo can be years old.
//

import XCTest
@testable import EncameraCore

final class AppGroupFileAccessStagingTests: XCTestCase {

    private var directory: URL!
    private var fileAccess: AppGroupFileAccess!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupFileAccessStagingTests-\(UUID().uuidString)")
        fileAccess = AppGroupFileAccess(importDirectoryURL: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCopiedMediaIsStampedWithTheTimeItWasStaged() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpeg")
        try Data([0xFF]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let yearsAgo = Date(timeIntervalSinceNow: -3 * 365 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: yearsAgo], ofItemAtPath: source.path)

        let staged = try await fileAccess.save(media: CleartextMedia(source: source)) { _ in }

        let stagedAt = try XCTUnwrap(modificationDate(of: staged))
        XCTAssertLessThan(abs(stagedAt.timeIntervalSinceNow), 60)
    }

    func testDeleteMediaStagedBeforeKeepsNewerAndExcludedFiles() throws {
        let cutoff = Date()
        let old = try stage("old.jpeg", stagedAt: cutoff.addingTimeInterval(-60))
        let oldButClaimed = try stage("claimed.jpeg", stagedAt: cutoff.addingTimeInterval(-60))
        let new = try stage("new.jpeg", stagedAt: cutoff.addingTimeInterval(60))

        let deleted = fileAccess.deleteMedia(stagedBefore: cutoff, excluding: [oldButClaimed])

        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldButClaimed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    func testPendingMediaURLsListsOnlyMedia() throws {
        _ = try stage("photo.jpeg", stagedAt: Date())
        _ = try stage("notes.txt", stagedAt: Date())

        XCTAssertEqual(fileAccess.pendingMediaURLs().map(\.lastPathComponent), ["photo.jpeg"])
        XCTAssertEqual(fileAccess.pendingMediaCount(), 1)
    }

    private func stage(_ name: String, stagedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stagedAt], ofItemAtPath: url.path)
        return url
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
