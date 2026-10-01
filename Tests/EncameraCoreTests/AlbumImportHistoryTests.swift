//
//  AlbumImportHistoryTests.swift
//  EncameraCoreTests
//
//  The per-album import history file: what the Import History screen reads, and
//  the only record of which photo-library originals an import may still delete.
//

import XCTest
@testable import EncameraCore

final class AlbumImportHistoryTests: XCTestCase {

    private var directory: URL!
    private let key: [UInt8] = (0..<32).map { _ in UInt8.random(in: 0...255) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumImportHistoryTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeHistory(key: [UInt8]? = nil, name: String = "history.encimports") -> AlbumImportHistory {
        AlbumImportHistory(albumId: "Album_local", keyBytes: key ?? self.key,
                           fileURL: directory.appendingPathComponent(name))
    }

    private func record(_ id: String, minutesAgo: Double = 0, assets: [String] = ["asset-1"],
                        state: ImportHistoryRecord.State = .completed) -> ImportHistoryRecord {
        ImportHistoryRecord(id: id,
                            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
                            source: .photos,
                            importedCount: assets.count,
                            requestedCount: assets.count,
                            assetIdentifiers: assets,
                            state: state)
    }

    func testMissingFileReadsAsEmpty() {
        XCTAssertEqual(makeHistory().records(), [])
    }

    func testAppendedRecordsRoundTripNewestFirst() throws {
        let history = makeHistory()
        try history.append(record("old", minutesAgo: 10))
        try history.append(record("new", minutesAgo: 1))

        XCTAssertEqual(makeHistory().records().map(\.id), ["new", "old"])
    }

    func testAppendingSameBatchReplacesIt() throws {
        let history = makeHistory()
        try history.append(record("batch", assets: ["a"]))
        try history.append(record("batch", assets: ["a", "b"]))

        XCTAssertEqual(history.records().count, 1)
        XCTAssertEqual(history.records().first?.assetIdentifiers, ["a", "b"])
    }

    func testHistoryKeepsNewest200Batches() throws {
        let history = makeHistory()
        for index in 0..<AlbumImportHistory.maximumRecords {
            try history.append(record("seed-\(index)", minutesAgo: Double(index + 1)))
        }
        try history.append(record("latest"))

        let ids = history.records().map(\.id)
        XCTAssertEqual(ids.count, 200)
        XCTAssertEqual(ids.first, "latest")
        XCTAssertFalse(ids.contains("seed-199"), "The oldest batch is dropped")
        XCTAssertTrue(ids.contains("seed-198"))
    }

    func testMarkDeletedStampsOnlyTheNamedBatches() throws {
        let history = makeHistory()
        try history.append(record("one", minutesAgo: 2))
        try history.append(record("two", minutesAgo: 1))
        try history.markDeletedFromLibrary(ids: ["one"])

        let byId = Dictionary(uniqueKeysWithValues: history.records().map { ($0.id, $0) })
        XCTAssertNotNil(byId["one"]?.deletedFromLibraryAt)
        XCTAssertFalse(byId["one"]!.canDeleteFromLibrary)
        XCTAssertNil(byId["two"]?.deletedFromLibraryAt)
        XCTAssertTrue(byId["two"]!.canDeleteFromLibrary)
    }

    func testRecordWithoutAssetsCannotBeDeletedFromLibrary() {
        XCTAssertFalse(record("files", assets: []).canDeleteFromLibrary)
    }

    func testRemoveAndRemoveAll() throws {
        let history = makeHistory()
        try history.append(record("one", minutesAgo: 2))
        try history.append(record("two", minutesAgo: 1))

        try history.remove(id: "one")
        XCTAssertEqual(history.records().map(\.id), ["two"])

        try history.removeAll()
        XCTAssertEqual(history.records(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.fileURL.path))
    }

    func testFileIsEncryptedAndExcludedFromBackup() throws {
        let history = makeHistory()
        try history.append(record("batch", assets: ["PLAINTEXT-ASSET-ID/L0/001"]))

        let raw = try Data(contentsOf: history.fileURL)
        XCTAssertNil(raw.range(of: Data("PLAINTEXT-ASSET-ID".utf8)), "Asset ids must not be stored in the clear")
        let values = try history.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFileWrittenWithAnotherKeyReadsAsEmpty() throws {
        try makeHistory().append(record("batch"))
        let otherKey: [UInt8] = (0..<32).map { _ in UInt8.random(in: 0...255) }
        XCTAssertEqual(makeHistory(key: otherKey).records(), [])
    }

    func testCorruptFileReadsAsEmptyAndIsReplacedByNextAppend() throws {
        let history = makeHistory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a history file".utf8).write(to: history.fileURL)
        XCTAssertEqual(history.records(), [])

        try history.append(record("fresh"))
        XCTAssertEqual(history.records().map(\.id), ["fresh"])
    }

    func testFileLocationIsKeyedByAlbumIdHash() {
        let url = AlbumImportHistory.fileURL(forAlbumId: "Holiday_cloudKit")
        XCTAssertEqual(url.deletingLastPathComponent(), MediaIndexStore.indexDirectoryURL())
        XCTAssertEqual(url.pathExtension, "encimports")
        XCTAssertFalse(url.lastPathComponent.contains("Holiday"), "No album name on disk")
        XCTAssertNotEqual(url, AlbumImportHistory.fileURL(forAlbumId: "Holiday_local"))
    }
}
