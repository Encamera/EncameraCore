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
                            mediaIdsByAssetId: Dictionary(uniqueKeysWithValues: assets.map { ($0, "media-\($0)") }),
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

    // MARK: - Asset id ↔ media id

    func testRecordRoundTripsMediaIdsPerAsset() throws {
        let history = makeHistory()
        let mapping = ["asset-1": "media-A", "asset-2": "media-B"]
        try history.append(ImportHistoryRecord(id: "batch", createdAt: Date(), source: .photos,
                                               importedCount: 2, requestedCount: 2,
                                               assetIdentifiers: ["asset-1", "asset-2"],
                                               mediaIdsByAssetId: mapping, state: .completed))

        let stored = try XCTUnwrap(makeHistory().records().first)
        XCTAssertEqual(stored.mediaIdsByAssetId, mapping)
        XCTAssertTrue(stored.isVerifiable)

        let plaintext = try MediaIndexStore.decrypt(Data(contentsOf: history.fileURL), keyBytes: key)
        let payload = try JSONDecoder().decode(AlbumImportHistory.Payload.self, from: plaintext)
        XCTAssertEqual(payload.version, 2, "Records carrying the mapping are written as version 2")
    }

    func testV1RecordDecodesWithoutMediaIds() throws {
        // A version 1 file, as written before records paired assets with media.
        let v2 = try JSONEncoder().encode(AlbumImportHistory.Payload(records: [record("legacy", assets: ["a", "b"])]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: v2) as? [String: Any])
        json["version"] = 1
        json["records"] = (json["records"] as? [[String: Any]])?.map { record -> [String: Any] in
            var record = record
            record.removeValue(forKey: "mediaIdsByAssetId")
            return record
        }
        let v1 = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(v1.range(of: Data("mediaIdsByAssetId".utf8)))
        let history = makeHistory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MediaIndexStore.encrypt(v1, keyBytes: key).write(to: history.fileURL)

        let legacy = try XCTUnwrap(history.records().first)
        XCTAssertEqual(legacy.id, "legacy")
        XCTAssertEqual(legacy.assetIdentifiers, ["a", "b"])
        XCTAssertNil(legacy.mediaIdsByAssetId)
        XCTAssertFalse(legacy.isVerifiable, "A record without media ids cannot be checked against the album")
        XCTAssertFalse(legacy.canDeleteFromLibrary, "so it never offers deleting originals")
        XCTAssertEqual(legacy.libraryOriginals(liveMediaIds: ["media-a", "media-b"]).liveAssetIdentifiers, [])
    }

    func testLiveAssetIdsExcludeMediaNoLongerInIndex() {
        let batch = ImportHistoryRecord(id: "batch", createdAt: Date(), source: .photos,
                                        importedCount: 3, requestedCount: 3,
                                        assetIdentifiers: ["asset-1", "asset-2", "asset-3"],
                                        mediaIdsByAssetId: ["asset-1": "media-1", "asset-2": "media-2", "asset-3": "media-3"],
                                        state: .completed)

        let originals = batch.libraryOriginals(liveMediaIds: ["media-1", "media-3", "unrelated"])

        XCTAssertEqual(originals.liveAssetIdentifiers, ["asset-1", "asset-3"])
        XCTAssertEqual(originals.goneCount, 1)
        XCTAssertTrue(batch.libraryOriginals(liveMediaIds: []).isEmpty, "An empty album keeps every original")
        XCTAssertEqual(batch.libraryOriginals(liveMediaIds: []).goneCount, 3)
    }

    func testFileLocationIsKeyedByAlbumIdHash() {
        let url = AlbumImportHistory.fileURL(forAlbumId: "Holiday_cloudKit")
        XCTAssertEqual(url.deletingLastPathComponent(), MediaIndexStore.indexDirectoryURL())
        XCTAssertEqual(url.pathExtension, "encimports")
        XCTAssertFalse(url.lastPathComponent.contains("Holiday"), "No album name on disk")
        XCTAssertNotEqual(url, AlbumImportHistory.fileURL(forAlbumId: "Holiday_local"))
    }
}
