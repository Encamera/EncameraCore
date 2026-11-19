//
//  PreviewAtomicWriteTests.swift
//  EncameraCoreTests
//
//  A saved preview replaces the old file whole: it is written beside it and
//  renamed into place, so no reader sees a torn file or a stale tail.
//

import XCTest
@testable import EncameraCore

final class PreviewAtomicWriteTests: XCTestCase {

    private let albumKey = PrivateKey(keyBytes: Array(repeating: 0x5C, count: 32),
                                      creationDate: Date(timeIntervalSince1970: 3_000))

    private var album: Album!
    private var mediaID: String!

    override func setUpWithError() throws {
        album = Album(name: "preview-atomic-\(UUID().uuidString.prefix(8))",
                      storageOption: .local,
                      creationDate: Date(),
                      key: albumKey)
        try album.storageOption.modelForType.init(album: album).initializeDirectories()
        mediaID = "preview-atomic-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        let model = album.storageOption.modelForType.init(album: album)
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: previewURL)
        for leftover in tempFiles() {
            try? FileManager.default.removeItem(at: leftover)
        }
    }

    // MARK: - Helpers

    private var previewURL: URL {
        album.storageOption.modelForType.init(album: album).previewURLForMedia(withID: mediaID)
    }

    private func makeAccess() async -> DiskFileAccess {
        let keyManager = DemoKeyManager(keys: [albumKey])
        keyManager.currentKey = albumKey
        let access = DiskFileAccess()
        await access.configure(for: album, albumManager: AlbumManager(keyManager: keyManager))
        return access
    }

    /// A preview whose JSON spans about `blocks` encryption blocks of 20 KB.
    private func preview(blocks: Int, fill: UInt8) -> PreviewModel {
        // Base64 grows the bytes by 4/3, so 15 KB of thumbnail is about one block.
        let thumbnail = Data(repeating: fill, count: blocks * 15_000)
        return PreviewModel(thumbnailMedia: CleartextMedia(source: thumbnail, mediaType: .photo, id: mediaID))
    }

    private var sourceMedia: CleartextMedia {
        CleartextMedia(source: Data(), mediaType: .photo, id: mediaID)
    }

    private func decryptPreviewFile(with access: DiskFileAccess) async throws -> PreviewModel {
        let encrypted = EncryptedMedia(source: .url(previewURL), mediaType: .preview, id: mediaID)
        let cleartext = try await access.loadMediaInMemory(media: encrypted, progress: { _ in })
        return try PreviewModel(source: cleartext)
    }

    /// Hidden temporary previews this test's media id left in the preview directory.
    private func tempFiles() -> [URL] {
        let directory = previewURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(".\(mediaID!).") }.map { directory.appendingPathComponent($0) }
    }

    private func fileIdentifier(of url: URL) throws -> NSObject? {
        try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
    }

    // MARK: - Tests

    func testShorterPreviewOverwritingLongerOneStillDecrypts() async throws {
        let access = await makeAccess()
        try await access.savePreview(preview: preview(blocks: 3, fill: 0xAA), sourceMedia: sourceMedia)
        let shorter = preview(blocks: 1, fill: 0xBB)
        try await access.savePreview(preview: shorter, sourceMedia: sourceMedia)

        let loaded = try await decryptPreviewFile(with: access)

        XCTAssertEqual(loaded.thumbnailMedia.data, shorter.thumbnailMedia.data,
                       "the shorter preview decrypts whole, with no tail of the longer one after it")
    }

    func testSavePreviewReplacesTheFileInsteadOfWritingIntoIt() async throws {
        let access = await makeAccess()
        try await access.savePreview(preview: preview(blocks: 2, fill: 0x11), sourceMedia: sourceMedia)
        let oldBytes = try Data(contentsOf: previewURL)
        let oldIdentifier = try fileIdentifier(of: previewURL)
        let reader = try FileHandle(forReadingFrom: previewURL)
        defer { try? reader.close() }

        try await access.savePreview(preview: preview(blocks: 1, fill: 0x22), sourceMedia: sourceMedia)

        XCTAssertEqual(try reader.readToEnd(), oldBytes,
                       "a reader that opened the old preview keeps reading all of it")
        XCTAssertNotEqual(try fileIdentifier(of: previewURL), oldIdentifier,
                          "the path now names a new file rather than the rewritten old one")
    }

    func testSavedPreviewKeepsKeyUUIDXattrAndBackupFlag() async throws {
        let access = await makeAccess()
        try await access.savePreview(preview: preview(blocks: 1, fill: 0x33), sourceMedia: sourceMedia)

        XCTAssertEqual(try ExtendedAttributesUtil.getKeyUUID(for: previewURL), albumKey.uuid,
                       "the key stamp set on the temporary file survives the rename")
        let values = try previewURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, false, "a local album's preview is backed up")
    }

    func testSavePreviewLeavesNoTempFilesBehind() async throws {
        let access = await makeAccess()
        try await access.savePreview(preview: preview(blocks: 1, fill: 0x44), sourceMedia: sourceMedia)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path), "precondition: the preview was saved")
        XCTAssertEqual(tempFiles(), [], "a successful save leaves no temporary file")

        // A non-empty directory at the preview path makes the rename fail.
        try FileManager.default.removeItem(at: previewURL)
        try FileManager.default.createDirectory(at: previewURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: previewURL.appendingPathComponent("blocker").path, contents: Data())
        do {
            try await access.savePreview(preview: preview(blocks: 1, fill: 0x55), sourceMedia: sourceMedia)
            XCTFail("the rename onto a non-empty directory should fail")
        } catch {}

        XCTAssertEqual(tempFiles(), [], "a failed save removes its temporary file")
    }

    func testCancelledPreviewWriteKeepsTheExistingPreview() async throws {
        let access = await makeAccess()
        let existing = preview(blocks: 2, fill: 0x66)
        try await access.savePreview(preview: existing, sourceMedia: sourceMedia)
        let source = sourceMedia

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await access.savePreview(preview: self.preview(blocks: 1, fill: 0x77), sourceMedia: source)
        }
        _ = await cancelled.result

        let loaded = try await decryptPreviewFile(with: access)
        XCTAssertEqual(loaded.thumbnailMedia.data, existing.thumbnailMedia.data,
                       "a cancelled write leaves the earlier preview in place")
        XCTAssertEqual(tempFiles(), [], "and removes its own temporary file")
    }
}
