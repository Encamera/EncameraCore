//
//  LivePhotoComponentIntegrityTests.swift
//  EncameraCoreTests
//
//  A Live Photo is two files sharing one id — `<id>.encimage` and `<id>.encvideo` —
//  collapsed into a single `MediaIndexEntry` carrying `hasPhotoComponent` /
//  `hasVideoComponent`. Nothing else records that an item is live: if the index
//  loses the video flag, the item renders as a plain still and its `.encvideo`
//  becomes invisible.
//
//  These tests pin the two properties that keep the index and the disk in
//  agreement for a half-recorded Live Photo:
//
//  1. `reconcile` must repair an entry whose components disagree with disk, not
//     just add/remove whole ids. Any partial save (a component that threw after
//     writing its file, or a gallery refresh that indexed the item between the
//     photo and the video write) leaves exactly that state, and until it is
//     repaired the item is permanently a still.
//  2. `delete` must remove every component file for the id, not only the
//     components the (possibly wrong) index knew about — otherwise the orphaned
//     `.encvideo` resurfaces as a separate 1–2 second video.
//

import XCTest
import UIKit
@testable import EncameraCore

final class LivePhotoComponentIntegrityTests: XCTestCase {

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeAlbum() -> Album {
        let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        return Album(name: "live-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
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

    private func makePhoto(id: String) throws -> InteractableMedia<CleartextMedia> {
        try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
        ])
    }

    /// Builds the exact on-disk state a half-recorded Live Photo leaves behind:
    /// `<id>.encimage` and `<id>.encvideo` both present and decryptable under the
    /// album key, but the index holding a photo-only entry for `id`.
    ///
    /// The `.encvideo` is a real encrypted file (a second saved photo's ciphertext
    /// moved into the video slot) so the reconcile's metadata read behaves exactly
    /// as it does in production rather than hitting an unreadable-file path.
    private func makeHalfRecordedLivePhoto(
        backend: DiskMediaBackend,
        album: Album,
        model: DataStorageModel
    ) async throws -> String {
        let liveID = UUID().uuidString
        let donorID = UUID().uuidString

        _ = try await backend.save(media: try makePhoto(id: liveID), metadata: nil, progress: { _ in })
        _ = try await backend.save(media: try makePhoto(id: donorID), metadata: nil, progress: { _ in })

        // Move the donor's ciphertext into the Live Photo's video slot, then drop
        // the donor entirely — leaving `<liveID>.encvideo` beside `<liveID>.encimage`.
        let donorPhotoURL = model.driveURLForMedia(withID: donorID, type: .photo)
        let liveVideoURL = model.driveURLForMedia(withID: liveID, type: .video)
        try FileManager.default.moveItem(at: donorPhotoURL, to: liveVideoURL)
        try? FileManager.default.removeItem(at: model.previewURLForMedia(withID: donorID))

        // The index now reflects the bug: one photo-only entry for the Live Photo,
        // nothing for the (now gone) donor.
        let store = MediaIndexStore(album: album)
        try await store.replace(with: [
            MediaIndexEntry(
                id: liveID,
                hasPhotoComponent: true,
                hasVideoComponent: false,
                dateEncrypted: Date(),
                dateTaken: Date(),
                subtypeRawValue: MediaFilterOptions.stillImage.rawValue
            )
        ])

        return liveID
    }

    private func albumFiles(_ model: DataStorageModel, id: String) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: model.baseURL.path
        )) ?? []
        return contents.filter { $0.hasPrefix(id) }.sorted()
    }

    // MARK: - Reconcile must repair components, not just whole ids

    /// The load-bearing repair. `reconcile` diffs disk against the index by **id**:
    /// an id already present is neither "added" nor "removed", and the
    /// modification check only catches files newer than the index file itself —
    /// which a busy album rewrites constantly. So a photo-only entry with an
    /// `.encvideo` sibling on disk is never revisited and the item stays a still
    /// forever. Reconcile must notice the component mismatch and heal it.
    func testReconcileRestoresMissingVideoComponentForLivePhotoOnDisk() async throws {
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))
        let liveID = try await makeHalfRecordedLivePhoto(backend: backend, album: album, model: model)

        XCTAssertEqual(
            albumFiles(model, id: liveID).filter { $0.hasSuffix(MediaType.video.encryptedFileExtension) }.count,
            1,
            "precondition: the paired video is on disk"
        )

        await backend.reconcile()

        let entry = await backend.mediaIndex()?.entries.first { $0.id == liveID }
        XCTAssertNotNil(entry, "the Live Photo must still be indexed")
        XCTAssertTrue(entry?.hasPhotoComponent ?? false, "the still component must survive the repair")
        XCTAssertTrue(
            entry?.hasVideoComponent ?? false,
            "reconcile must pick up the `.encvideo` sibling so the item renders as a Live Photo again"
        )
    }

    /// The repair must be symmetric: an entry claiming a video component whose
    /// file is gone has to lose the flag, or the gallery materializes a URL that
    /// does not exist and playback fails.
    func testReconcileClearsVideoComponentWhenPairedVideoIsGone() async throws {
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))
        let liveID = try await makeHalfRecordedLivePhoto(backend: backend, album: album, model: model)

        // Heal it first, then take the video away behind the index's back.
        await backend.reconcile()
        try FileManager.default.removeItem(at: model.driveURLForMedia(withID: liveID, type: .video))

        await backend.reconcile()

        let entry = await backend.mediaIndex()?.entries.first { $0.id == liveID }
        XCTAssertNotNil(entry, "the still component keeps the entry alive")
        XCTAssertTrue(entry?.hasPhotoComponent ?? false)
        XCTAssertFalse(
            entry?.hasVideoComponent ?? true,
            "reconcile must drop a video component whose file no longer exists"
        )
    }

    // MARK: - Delete must not orphan a component

    /// What the user actually reports: they delete the photo that "isn't live",
    /// and a 1–2 second video appears in its place. Delete is handed whatever the
    /// index materialized — a photo-only item — so `.encvideo` survives on disk,
    /// and the next reconcile re-adds it as a standalone video. Deleting a logical
    /// item must clear every component file for that id.
    func testDeletingAHalfRecordedLivePhotoLeavesNoOrphanedVideo() async throws {
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer {
            try? FileManager.default.removeItem(at: model.baseURL)
            try? MediaIndexStore.clearAllIndexes()
        }

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: makeManager(for: album))
        let liveID = try await makeHalfRecordedLivePhoto(backend: backend, album: album, model: model)

        // Exactly what `InteractableMediaFileAccess.materialize` builds from the
        // photo-only entry the gallery is showing.
        let photoOnly = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(
                source: .url(model.driveURLForMedia(withID: liveID, type: .photo)),
                mediaType: .photo,
                id: liveID
            )
        ])

        try await backend.delete(media: [photoOnly])

        XCTAssertEqual(
            albumFiles(model, id: liveID),
            [],
            "deleting the item must take the paired video with it — a survivor resurfaces as a separate video"
        )

        // And it must stay gone: a reconcile has nothing left to re-add.
        await backend.reconcile()
        let entry = await backend.mediaIndex()?.entries.first { $0.id == liveID }
        XCTAssertNil(entry, "no component may survive to be re-indexed as a standalone video")
    }
}
