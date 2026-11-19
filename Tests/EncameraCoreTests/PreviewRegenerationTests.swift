//
//  PreviewRegenerationTests.swift
//  EncameraCoreTests
//
//  A save leaves the preview it wrote in the cache, and a broken or locked
//  preview is still handled the way it was before previews were cached on save.
//

import XCTest
@testable import EncameraCore

final class PreviewRegenerationTests: XCTestCase {

    private let albumKey = PrivateKey(keyBytes: Array(repeating: 0x3D, count: 32),
                                      creationDate: Date(timeIntervalSince1970: 4_000))

    private var album: Album!
    private var model: DataStorageModel!
    private var mediaID: String!

    override func setUpWithError() throws {
        album = Album(name: "preview-regen-\(UUID().uuidString.prefix(8))",
                      storageOption: .local,
                      creationDate: Date(),
                      key: albumKey)
        model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        mediaID = "preview-regen-\(UUID().uuidString)"
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

    private func photoCleartext() -> CleartextMedia {
        CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: mediaID)
    }

    /// Saves a real photo, so a regeneration has a source to make the preview from.
    private func savePhoto(with access: DiskFileAccess) async throws -> EncryptedMedia {
        let saved = try await access.save(media: photoCleartext(), progress: { _ in })
        return try XCTUnwrap(saved)
    }

    private func photoThumbnailData() async throws -> Data? {
        try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: photoCleartext()).data
    }

    private func breakPreview(_ byte: UInt8) throws {
        try? FileManager.default.removeItem(at: previewURL)
        try Data(repeating: byte, count: 512).write(to: previewURL)
        DiskFileAccess.removeCachedPreview(forMediaID: mediaID)
    }

    // MARK: - Tests

    func testBrokenPreviewIsRegenerated() async throws {
        let access = await makeAccess()
        let saved = try await savePhoto(with: access)
        try breakPreview(0x04)

        let loaded = try await access.loadMediaPreview(for: saved)

        let photoThumbnail = try await photoThumbnailData()
        XCTAssertEqual(loaded.thumbnailMedia.data, photoThumbnail, "a broken preview is regenerated from the photo")
    }

    func testSaveFillsThePreviewCache() async throws {
        let access = await makeAccess()
        let saved = try await savePhoto(with: access)
        let sourceURL = try XCTUnwrap(saved.url)
        try FileManager.default.removeItem(at: previewURL)
        try FileManager.default.removeItem(at: sourceURL)

        let loaded = try await access.loadMediaPreview(for: saved)

        let photoThumbnail = try await photoThumbnailData()
        XCTAssertEqual(loaded.thumbnailMedia.data, photoThumbnail,
                       "the save's preview comes from the cache, with neither the preview nor the photo on disk")
    }

    func testUnreadablePreviewWithAbsentKeyIsNotRegenerated() async throws {
        let unstoredKey = PrivateKey(keyBytes: Array(repeating: 0x77, count: 32),
                                     creationDate: Date(timeIntervalSince1970: 5_000))
        let access = await makeAccess()
        let saved = try await savePhoto(with: access)
        try await access.savePreview(preview: PreviewModel(thumbnailMedia: CleartextMedia(source: Data([1, 2, 3]),
                                                                                         mediaType: .photo,
                                                                                         id: mediaID)),
                                     sourceMedia: saved,
                                     underKey: unstoredKey)
        let before = try Data(contentsOf: previewURL)
        DiskFileAccess.removeCachedPreview(forMediaID: mediaID)

        do {
            _ = try await access.loadMediaPreview(for: saved)
            XCTFail("a preview under a key this device lacks cannot load")
        } catch FileAccessError.missingKeyForMedia {
        } catch {
            XCTFail("expected missingKeyForMedia, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: previewURL), before, "the preview was not regenerated")
    }
}
