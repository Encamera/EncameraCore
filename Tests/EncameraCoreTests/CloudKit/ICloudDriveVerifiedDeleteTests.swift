//
//  ICloudDriveVerifiedDeleteTests.swift
//  EncameraCoreTests
//
//  The verified delete removes an iCloud Drive file only once the server holds
//  its record in the album with the file's size. These run against a real folder
//  with a real marker file and real files; the server is `MockCloudKitMediaStore`,
//  and only iCloud's download state and metadata sizes are faked, through
//  `RecordingFileSystem`.
//

import XCTest
@testable import EncameraCore

final class ICloudDriveVerifiedDeleteTests: XCTestCase {

    private var folder: URL!
    private var albumID: String!
    private var store: MockCloudKitMediaStore!
    private var fileSystem: RecordingFileSystem!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("verified-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        albumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: folder)
        store = MockCloudKitMediaStore()
        fileSystem = RecordingFileSystem()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        super.tearDown()
    }

    // MARK: - Fixture

    /// The real file system, except that `evicted` files report their bytes as
    /// absent and metadata sizes come from `metadataSizes`. Records every on-disk
    /// size read, which for an evicted file would need its bytes.
    private final class RecordingFileSystem: ICloudDriveVerifiedDeleteFileSystem, @unchecked Sendable {
        private let lock = NSLock()
        private let disk = ICloudDriveVerifiedDeleteDiskFileSystem()
        private var _evicted: Set<URL> = []
        private var _metadataSizes: [String: Int64]? = [:]
        private var _diskSizeOverrides: [URL: Int64] = [:]
        private var _diskSizeReads: [URL] = []
        private var _removed: [URL] = []

        var evicted: Set<URL> {
            get { lock.withLock { _evicted } }
            set { lock.withLock { _evicted = newValue } }
        }
        var metadataSizes: [String: Int64]? {
            get { lock.withLock { _metadataSizes } }
            set { lock.withLock { _metadataSizes = newValue } }
        }
        /// Sizes `fileSize(at:)` reports in place of the file's.
        var diskSizeOverrides: [URL: Int64] {
            get { lock.withLock { _diskSizeOverrides } }
            set { lock.withLock { _diskSizeOverrides = newValue } }
        }
        var diskSizeReads: [URL] { lock.withLock { _diskSizeReads } }
        var removed: [URL] { lock.withLock { _removed } }

        func existingForms(of url: URL) -> [URL] { disk.existingForms(of: url) }

        func isMaterialized(_ url: URL) -> Bool {
            !evicted.contains(url) && FileManager.default.fileExists(atPath: url.path)
        }

        func fileSize(at url: URL) -> Int64? {
            lock.withLock { _diskSizeReads.append(url) }
            return diskSizeOverrides[url] ?? disk.fileSize(at: url)
        }

        func metadataSizes(inFolder folder: URL) async -> [String: Int64]? { metadataSizes }

        func coordinatedRemove(_ url: URL, expectedSize: Int64?) throws -> Bool {
            let removed = try disk.coordinatedRemove(url, expectedSize: expectedSize)
            if removed { lock.withLock { _removed.append(url) } }
            return removed
        }
    }

    private func operation() -> ICloudDriveVerifiedDelete {
        ICloudDriveVerifiedDelete(store: store, fileSystem: fileSystem,
                                  markerConflictVersions: { _ in [] })
    }

    private func delete(_ recordName: String) async -> ICloudDriveVerifiedDeleteResult {
        await operation().delete(recordName: recordName, albumID: albumID, folder: folder)
    }

    private func fileURL(_ mediaID: String, _ type: MediaType) -> URL {
        folder.appendingPathComponent("\(mediaID).\(type.encryptedFileExtension)")
    }

    /// Writes `byteCount` bytes under the component's name and returns its record name.
    @discardableResult
    private func writeFile(_ mediaID: String, _ type: MediaType = .photo, byteCount: Int = 128) throws -> String {
        try Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) }).write(to: fileURL(mediaID, type))
        return MediaRecordName.componentRecordName(mediaID: mediaID, type: type)
    }

    private func addRecord(_ mediaID: String, _ type: MediaType = .photo, albumID: String? = nil, sizeBytes: Int64) {
        store.metadataToReturn.append(CloudKitMediaMetadata(
            recordName: MediaRecordName.componentRecordName(mediaID: mediaID, type: type),
            albumID: albumID ?? self.albumID, mediaID: mediaID, mediaType: type, createdAt: Date(),
            sizeBytes: sizeBytes, creationDeviceID: "other-device", schemaVersion: 1, recordChangeTag: "tag"))
    }

    private func skipReason(_ result: ICloudDriveVerifiedDeleteResult,
                            file: StaticString = #filePath, line: UInt = #line) -> ICloudDriveVerifiedDeleteSkipReason? {
        guard case .skipped(let reason) = result else {
            XCTFail("expected a skip, got \(result)", file: file, line: line)
            return nil
        }
        return reason
    }

    private func assertDeleted(_ result: ICloudDriveVerifiedDeleteResult,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .deleted = result else {
            XCTFail("expected a delete, got \(result)", file: file, line: line)
            return
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Confirmed records

    func testDeletesFileWhoseRecordIsConfirmed() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 300)
        addRecord(id, sizeBytes: 300)

        assertDeleted(await delete(recordName))

        XCTAssertFalse(exists(fileURL(id, .photo)))
        XCTAssertEqual(store.fetchRecordMetadataCalls, [recordName], "confirmed with one fresh fetch of this record")
        XCTAssertTrue(exists(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder)), "the marker stays")
    }

    func testDeleteLeavesPreviewUntouched() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 200)
        addRecord(id, sizeBytes: 200)
        let previewURL = LocalStorageModel.previewURL(forMediaID: id)
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previewBytes = Data("preview".utf8)
        try previewBytes.write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }

        assertDeleted(await delete(recordName))

        XCTAssertFalse(exists(fileURL(id, .photo)))
        XCTAssertEqual(try? Data(contentsOf: previewURL), previewBytes, "the preview outlives the iCloud Drive file")
    }

    // MARK: - Records that do not confirm

    func testKeepsFileWhenRecordMissing() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id)

        let skipped1 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped1), .recordMissing)
        XCTAssertTrue(exists(fileURL(id, .photo)))
        XCTAssertEqual(fileSystem.removed, [])
    }

    func testKeepsFileWhenRecordIsInAnotherAlbum() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 128)
        addRecord(id, albumID: "other-album", sizeBytes: 128)

        let skipped2 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped2), .wrongAlbum(owner: "other-album"))
        XCTAssertTrue(exists(fileURL(id, .photo)))
    }

    func testKeepsFileWhenRecordSizeDiffers() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 128)
        addRecord(id, sizeBytes: 127)

        let skipped3 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped3), .sizeMismatch)
        XCTAssertTrue(exists(fileURL(id, .photo)))
    }

    func testKeepsUnmigratedLivePhotoHalf() async throws {
        let id = UUID().uuidString
        let photo = try writeFile(id, .photo, byteCount: 100)
        let video = try writeFile(id, .video, byteCount: 900)
        addRecord(id, .photo, sizeBytes: 100)

        assertDeleted(await delete(photo))
        let skipped4 = await delete(video)
        XCTAssertEqual(skipReason(skipped4), .recordMissing)

        XCTAssertFalse(exists(fileURL(id, .photo)), "the photo half is in CloudKit")
        XCTAssertTrue(exists(fileURL(id, .video)), "the video half is not, so its file stays")
    }

    func testIgnoresIndexPresence() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id)
        let indexURL = folder.deletingLastPathComponent()
            .appendingPathComponent("verified-delete-\(UUID().uuidString).encindex")
        let index = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32), indexURL: indexURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: indexURL) }
        try await index.save(MediaIndex(entries: [
            MediaIndexEntry(id: id, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: Date(), dateTaken: nil, subtypeRawValue: 0,
                            photoLocation: .cloudKit, videoLocation: .cloudKit)
        ]))
        let indexed = await index.current()?.entries.first { $0.id == id }
        XCTAssertEqual(indexed?.photoLocation, .cloudKit, "precondition: the index says the bytes are in CloudKit")

        let skipped5 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped5), .recordMissing, "the server has no record")
        XCTAssertTrue(exists(fileURL(id, .photo)))
    }

    func testFetchErrorFailsWithoutDeleting() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 64)
        addRecord(id, sizeBytes: 64)
        store.fetchRecordMetadataError = CloudKitMediaStoreError.underlying(URLError(.notConnectedToInternet))

        guard case .failed = await delete(recordName) else { return XCTFail("expected a failure") }
        XCTAssertTrue(exists(fileURL(id, .photo)))
        XCTAssertEqual(fileSystem.removed, [])
    }

    // MARK: - Evicted files

    func testDeletesEvictedPlaceholderWithoutDownloading() async throws {
        let id = UUID().uuidString
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        let materialized = fileURL(id, .photo)
        let placeholder = ICloudPlaceholderName.placeholderURL(forMaterialized: materialized)
        try Data("brick".utf8).write(to: placeholder)
        fileSystem.metadataSizes = [materialized.lastPathComponent: 4_000_000]
        addRecord(id, sizeBytes: 4_000_000)

        assertDeleted(await delete(recordName))

        XCTAssertFalse(exists(placeholder), "the placeholder is removed as it is")
        XCTAssertFalse(exists(materialized), "nothing was downloaded into the file's place")
        XCTAssertEqual(fileSystem.diskSizeReads, [], "sized from metadata, never from the file's bytes")
        XCTAssertEqual(store.fetchBlobCount, 0)
    }

    func testDeletesFileEvictedInPlaceWithoutDownloading() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 16)
        let url = fileURL(id, .photo)
        fileSystem.evicted = [url]
        fileSystem.metadataSizes = [url.lastPathComponent: 5_000_000]
        addRecord(id, sizeBytes: 5_000_000)

        assertDeleted(await delete(recordName))

        XCTAssertFalse(exists(url))
        XCTAssertEqual(fileSystem.diskSizeReads, [], "an evicted file's on-disk size is the placeholder's")
    }

    func testKeepsEvictedFileWhoseSizeIsUnknown() async throws {
        let id = UUID().uuidString
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        let placeholder = ICloudPlaceholderName.placeholderURL(forMaterialized: fileURL(id, .photo))
        try Data("brick".utf8).write(to: placeholder)
        fileSystem.metadataSizes = nil
        addRecord(id, sizeBytes: 5)

        let skipped8 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped8), .sizeUnknown)
        XCTAssertTrue(exists(placeholder))
        XCTAssertEqual(store.fetchRecordMetadataCount, 0)
    }

    // MARK: - Folder and file

    func testSkipsFileInNoFormInTheFolder() async throws {
        let id = UUID().uuidString
        addRecord(id, sizeBytes: 10)

        let result = await delete(MediaRecordName.componentRecordName(mediaID: id, type: .photo))

        XCTAssertEqual(skipReason(result), .notInFolder)
        XCTAssertEqual(store.fetchRecordMetadataCount, 0)
    }

    func testKeepsFilesInFolderWhoseMarkerNamesAnotherAlbum() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 64)
        addRecord(id, sizeBytes: 64)
        try ICloudDriveAlbumMarkerFile(albumID: "other-album").write(toAlbumDirectory: folder)

        let skipped9 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped9),
                       .folderNotVerified(.markerNamesAnotherAlbum(albumID: "other-album")))
        XCTAssertTrue(exists(fileURL(id, .photo)))
    }

    func testKeepsFilesInFolderWithoutMarker() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 64)
        addRecord(id, sizeBytes: 64)
        try FileManager.default.removeItem(at: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder))

        let skipped10 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped10), .folderNotVerified(.markerAbsent))
        XCTAssertTrue(exists(fileURL(id, .photo)))
    }

    func testRejectsRecordNamesThatAreNotOneComponentFile() async throws {
        for recordName in ["", "abc", "abc#\(MediaType.preview.rawValue)", "../x#\(MediaType.photo.rawValue)",
                           ".encamera-cloudkit-album#\(MediaType.photo.rawValue)", "a/b#\(MediaType.photo.rawValue)"] {
            let skipped11 = await delete(recordName)
            XCTAssertEqual(skipReason(skipped11), .invalidRecordName, recordName)
        }
        XCTAssertTrue(exists(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder)))
        XCTAssertEqual(store.fetchRecordMetadataCount, 0)
    }

    func testKeepsFileRewrittenBeforeTheDelete() async throws {
        let id = UUID().uuidString
        let recordName = try writeFile(id, byteCount: 64)
        let url = fileURL(id, .photo)
        // The size read before the fetch matches the record; the file on disk by
        // the time of the coordinated delete does not.
        fileSystem.diskSizeOverrides = [url: 50]
        addRecord(id, sizeBytes: 50)

        let skipped12 = await delete(recordName)
        XCTAssertEqual(skipReason(skipped12), .sizeMismatch)
        XCTAssertTrue(exists(url))
    }
}
