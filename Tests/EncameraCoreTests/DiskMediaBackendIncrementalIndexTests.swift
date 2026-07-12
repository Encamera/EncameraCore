//
//  DiskMediaBackendIncrementalIndexTests.swift
//  EncameraCoreTests
//
//  Coverage for the incremental index maintenance the disk backend performs
//  on every mutation — the index must be current immediately after save,
//  delete, and deleteAllMedia, WITHOUT an intervening reconcile scan. This is
//  the disk counterpart to what the CloudKit coordinator has always done.
//

import XCTest
import UIKit
@testable import EncameraCore

final class DiskMediaBackendIncrementalIndexTests: XCTestCase {

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeAlbum() -> Album {
        let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        return Album(name: "disk-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
    }

    private func makeManager(for album: Album) -> MockAlbumManager {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        return MockAlbumManager(keyManager: keyManager)
    }

    /// A real 2×2 PNG so the save path's thumbnail generation succeeds.
    private func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    private func makePhoto(id: String = UUID().uuidString) throws -> InteractableMedia<CleartextMedia> {
        try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
        ])
    }

    /// A save must fold the new item into the index right away — `mediaIndex()`
    /// returns it without anyone calling `reconcile()`.
    func testSaveAddsEntryToIndexImmediately() async throws {
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))

        let id = UUID().uuidString
        _ = try await backend.save(media: try makePhoto(id: id), metadata: nil, progress: { _ in })

        let index = await backend.mediaIndex()
        XCTAssertEqual(index?.entries.count, 1, "save must add exactly one entry")
        XCTAssertEqual(index?.entries.first?.id, id)
        XCTAssertTrue(index?.entries.first?.hasPhotoComponent ?? false)
    }

    /// Deleting an item must drop it from the index immediately.
    func testDeleteRemovesEntryFromIndex() async throws {
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))

        let keepID = UUID().uuidString
        let dropID = UUID().uuidString
        let kept = try await backend.save(media: try makePhoto(id: keepID), metadata: nil, progress: { _ in })
        let dropped = try await backend.save(media: try makePhoto(id: dropID), metadata: nil, progress: { _ in })
        _ = kept
        let beforeDelete = await backend.mediaIndex()?.entries.count
        XCTAssertEqual(beforeDelete, 2, "precondition: both saved")

        if let dropped {
            try await backend.delete(media: [dropped])
        }

        let index = await backend.mediaIndex()
        XCTAssertEqual(index?.entries.count, 1, "delete must drop exactly the deleted id")
        XCTAssertEqual(index?.entries.first?.id, keepID)
    }

    /// `deleteAllMedia` must empty the index.
    func testDeleteAllMediaEmptiesIndex() async throws {
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))

        _ = try await backend.save(media: try makePhoto(), metadata: nil, progress: { _ in })
        _ = try await backend.save(media: try makePhoto(), metadata: nil, progress: { _ in })
        let beforeClear = await backend.mediaIndex()?.entries.count
        XCTAssertEqual(beforeClear, 2, "precondition: both saved")

        try await backend.deleteAllMedia()

        let afterClear = await backend.mediaIndex()?.entries.count
        XCTAssertEqual(afterClear, 0, "deleteAllMedia must empty the index")
    }
}
