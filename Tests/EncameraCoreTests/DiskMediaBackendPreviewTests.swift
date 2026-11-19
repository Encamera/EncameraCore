//
//  DiskMediaBackendPreviewTests.swift
//  EncameraCoreTests
//
//  A Live Photo saved to a disk album has one preview, made from its photo,
//  whatever order its components arrive in. The video never writes it.
//

import XCTest
@testable import EncameraCore

final class DiskMediaBackendPreviewTests: XCTestCase {

    private var album: Album!
    private var model: DataStorageModel!
    private var movieURL: URL!
    private var savedIDs: [String] = []

    override func setUp() async throws {
        let key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        album = Album(name: "disk-preview-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
        model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movieURL, seconds: 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: movieURL)
        for id in savedIDs {
            try? FileManager.default.removeItem(at: model.previewURLForMedia(withID: id))
        }
        try? MediaIndexStore.clearAllIndexes()
    }

    // MARK: - Helpers

    private func makeManager() -> MockAlbumManager {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        return MockAlbumManager(keyManager: keyManager)
    }

    private func makeBackend() async -> DiskMediaBackend {
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager())
        return backend
    }

    private func makeFileAccess() async -> DiskFileAccess {
        let access = DiskFileAccess()
        await access.configure(for: album, albumManager: makeManager())
        return access
    }

    private func newID() -> String {
        let id = UUID().uuidString
        savedIDs.append(id)
        return id
    }

    private func photoPart(id: String) -> CleartextMedia {
        CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
    }

    private func videoPart(id: String) -> CleartextMedia {
        CleartextMedia(source: .url(movieURL), mediaType: .video, id: id)
    }

    /// Read through a fresh URL: a URL caches the resource values it has read.
    private func fileIdentifier(of url: URL) throws -> NSObject? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
    }

    private func assertPreviewIsThePhotos(_ components: [CleartextMedia], id: String,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let live = try InteractableMedia(underlyingMedia: components)
        XCTAssertEqual(live.mediaType, .livePhoto, "precondition: the components make a Live Photo", file: file, line: line)

        let result = try await makeBackend().save(media: live, metadata: nil, progress: { _ in })
        let saved = try XCTUnwrap(result, file: file, line: line)
        let preview = try await makeBackend().loadMediaPreview(for: saved)

        XCTAssertNil(preview.videoDuration, "the preview is the photo's, not the video's frame", file: file, line: line)
        XCTAssertTrue(preview.isLivePhoto, file: file, line: line)
        let photoThumbnail = try await ThumbnailUtils.createThumbnailMediaFrom(cleartext: photoPart(id: id))
        XCTAssertEqual(preview.thumbnailMedia.data, photoThumbnail.data,
                       "the stored thumbnail is the photo's", file: file, line: line)
    }

    // MARK: - Tests

    func testLivePhotoPreviewComesFromThePhotoWhenVideoIsListedFirst() async throws {
        let id = newID()
        try await assertPreviewIsThePhotos([videoPart(id: id), photoPart(id: id)], id: id)
    }

    func testLivePhotoPreviewComesFromThePhotoWhenPhotoIsListedFirst() async throws {
        let id = newID()
        try await assertPreviewIsThePhotos([photoPart(id: id), videoPart(id: id)], id: id)
    }

    /// The backend saves a Live Photo's video with `writesPreview: false`. Saving
    /// it that way leaves the photo's preview file untouched.
    func testLivePhotoSaveWritesThePreviewOnce() async throws {
        let id = newID()
        let access = await makeFileAccess()
        _ = try await access.save(media: photoPart(id: id), progress: { _ in })
        let previewURL = model.previewURLForMedia(withID: id)
        let afterPhoto = try fileIdentifier(of: previewURL)

        _ = try await access.save(media: videoPart(id: id), writesPreview: false, progress: { _ in })

        XCTAssertEqual(try fileIdentifier(of: previewURL), afterPhoto,
                       "the video's save does not rewrite the photo's preview")
    }

    func testPlainVideoSaveStillWritesAPreviewWithDuration() async throws {
        let id = newID()
        let video = try InteractableMedia(underlyingMedia: [videoPart(id: id)])

        let result = try await makeBackend().save(media: video, metadata: nil, progress: { _ in })
        let saved = try XCTUnwrap(result)
        let preview = try await makeBackend().loadMediaPreview(for: saved)

        XCTAssertNotNil(preview.videoDuration, "a plain video still gets its own preview")
        XCTAssertFalse(preview.isLivePhoto)
    }
}
