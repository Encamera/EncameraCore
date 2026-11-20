//
//  PreviewNeedsDownloadTests.swift
//  EncameraCoreTests
//
//  A preview is never built from a file whose bytes are not on disk: the build
//  fails at once instead of waiting on an iCloud Drive download.
//

import XCTest
@testable import EncameraCore

final class PreviewNeedsDownloadTests: XCTestCase {

    private let albumKey = PrivateKey(keyBytes: Array(repeating: 0x5A, count: 32),
                                      creationDate: Date(timeIntervalSince1970: 5_000))

    private var album: Album!
    private var model: DataStorageModel!
    private var mediaID: String!

    override func setUpWithError() throws {
        album = Album(name: "preview-download-\(UUID().uuidString.prefix(8))",
                      storageOption: .local,
                      creationDate: Date(),
                      key: albumKey)
        model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        mediaID = "preview-download-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: previewURL)
        DiskFileAccess.removeCachedPreview(forMediaID: mediaID)
    }

    // MARK: - Helpers

    private var previewURL: URL { model.previewURLForMedia(withID: mediaID) }

    private func makeAccess() async -> DiskFileAccess {
        let keyManager = DemoKeyManager(keys: [albumKey])
        keyManager.currentKey = albumKey
        let access = DiskFileAccess()
        await access.configure(for: album, albumManager: AlbumManager(keyManager: keyManager))
        return access
    }

    /// Saves a photo and removes its preview, leaving the state of a file another
    /// device wrote: the encrypted file and nothing made from it.
    private func savePhotoWithoutPreview(with access: DiskFileAccess) async throws -> EncryptedMedia {
        let cleartext = CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: mediaID)
        let saved = try await access.save(media: cleartext, progress: { _ in })
        try FileManager.default.removeItem(at: previewURL)
        DiskFileAccess.removeCachedPreview(forMediaID: mediaID)
        return try XCTUnwrap(saved)
    }

    private func assertNotDownloaded(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case FileAccessError.iCloudFileNotDownloaded = error else {
            XCTFail("expected iCloudFileNotDownloaded, got \(error)", file: file, line: line)
            return
        }
    }

    // MARK: - Tests

    func testPreviewOfAFileNeedingDownloadFailsWithoutReadingIt() async throws {
        let access = await makeAccess()
        let saved = try await savePhotoWithoutPreview(with: access)

        await DiskFileAccess.$previewSourceNeedsDownload.withValue({ _ in true }) {
            do {
                _ = try await access.loadMediaPreview(for: saved)
                XCTFail("a preview must not be built from a file that needs download")
            } catch {
                assertNotDownloaded(error)
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path), "no preview is written")
    }

    func testPreviewIsBuiltOnceTheFileIsDownloaded() async throws {
        let access = await makeAccess()
        let saved = try await savePhotoWithoutPreview(with: access)

        await DiskFileAccess.$previewSourceNeedsDownload.withValue({ _ in true }) {
            do {
                _ = try await access.loadMediaPreview(for: saved)
                XCTFail("a preview must not be built from a file that needs download")
            } catch {
                assertNotDownloaded(error)
            }
        }
        let loaded = try await DiskFileAccess.$previewSourceNeedsDownload.withValue({ _ in false }) {
            try await access.loadMediaPreview(for: saved)
        }

        XCTAssertNotNil(loaded.thumbnailMedia.data, "the failed load is not remembered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path), "the preview is written")
    }

    /// More requests than there are preview slots, each for a file that needs
    /// download, leave every slot free for a capture's preview.
    func testFilesNeedingDownloadHoldNoPreviewSlot() async throws {
        let access = await makeAccess()
        let saved = try await savePhotoWithoutPreview(with: access)

        try await DiskFileAccess.$previewSourceNeedsDownload.withValue({ _ in true }) {
            for _ in 0..<12 {
                do {
                    _ = try await access.loadMediaPreview(for: saved)
                    XCTFail("a preview must not be built from a file that needs download")
                } catch {
                    assertNotDownloaded(error)
                }
            }
            let captureID = "preview-download-capture-\(UUID().uuidString)"
            defer {
                try? FileManager.default.removeItem(at: model.previewURLForMedia(withID: captureID))
                DiskFileAccess.removeCachedPreview(forMediaID: captureID)
            }
            let capture = CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: captureID)
            let preview = try await access.createPreview(for: capture)
            XCTAssertNotNil(preview.thumbnailMedia.data, "a capture held in memory still gets its preview")
        }
    }
}
