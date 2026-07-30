//
//  ICloudDriveLegacyContractTests.swift
//  EncameraCoreTests
//
//  ENC-106. iCloud Drive is deprecated as a *storage type*: it is closed to new
//  albums and never offered as a destination. It is NOT frozen — every album a
//  user already has on iCloud Drive stays fully writable until they migrate it,
//  including adding new photos to it.
//
//  Only the rejecting half of that contract was tested before this file. The
//  permitting half held purely by omission: `DiskFileAccess.save` has no
//  storage-type gate at all. The deprecation is a collection of gates, and the
//  natural instinct when tightening one is to reach for
//  `isStorageTypeOfferedForNewAlbums`,
//  which reports `.icloud` unavailable unconditionally. Doing that in the save
//  path would silently stop users adding photos to their legacy albums, and
//  nothing would have gone red. These tests are the thing that goes red.
//
//  The rejecting half already lives in `CloudKitMigrationManagerTests`
//  (`testCreateICloudDriveAlbumThrowsInAllBuildConfigurations`,
//  `testMoveToICloudDriveThrowsInAllBuildConfigurations`) and is not duplicated
//  here.
//

import XCTest
import UIKit
@testable import EncameraCore

final class ICloudDriveLegacyContractTests: XCTestCase {

    // MARK: - Fixtures

    /// Points `iCloudStorageModel` at a scratch directory for the duration of a
    /// test. Neither a simulator nor a unit-test host has a ubiquity container, so
    /// without this the `.icloud` paths cannot be executed at all — `rootURL`
    /// traps. Only the container root is substituted; everything downstream is the
    /// real `.icloud` code path, not a re-labelled local one.
    private func withICloudDriveRoot(_ body: () async throws -> Void) async rethrows {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("icloud-legacy-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = root
        defer {
            iCloudStorageModel.testContainerRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    private func randomKeyBytes() -> [UInt8] {
        (0..<32).map { _ in UInt8.random(in: 0...255) }
    }

    /// Lays the album's directories down directly. `AlbumManager.create` refuses
    /// `.icloud` unconditionally now — which is the point of the deprecation — so
    /// a legacy album can only be seeded the way an existing user's already is:
    /// as directories that predate the gate.
    private func seedLegacyAlbum() throws -> Album {
        let key = PrivateKey(name: "key", keyBytes: randomKeyBytes(), creationDate: Date())
        let album = Album(name: "legacy-\(UUID().uuidString)", storageOption: .icloud,
                          creationDate: Date(), key: key)
        try iCloudStorageModel(album: album).initializeDirectories()
        return album
    }

    private func backend(for album: Album) async -> (DiskMediaBackend, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        return (backend, albumManager)
    }

    private func tinyPNG() -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.pngData() ?? Data()
    }

    private func makePhoto(id: String = UUID().uuidString) throws -> InteractableMedia<CleartextMedia> {
        try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
        ])
    }

    private func cleanup(_ album: Album) {
        try? FileManager.default.removeItem(at: iCloudStorageModel(album: album).baseURL)
        try? MediaIndexStore.clearAllIndexes()
    }

    // MARK: - Allowed: writes to an existing album

    /// **The load-bearing test of ENC-106.** Adding new media to an album that is
    /// already on iCloud Drive must keep working. Asserts the full round trip —
    /// ciphertext written under the iCloud container, visible to enumeration, and
    /// decryptable back to the exact bytes that went in — so the test fails
    /// whether the save path is blocked outright or quietly writes somewhere else.
    ///
    /// Gate this save path on `isStorageTypeOfferedForNewAlbums` instead of letting it
    /// through and this test must go red.
    func testCanAddMediaToExistingICloudDriveAlbum() async throws {
        try await withICloudDriveRoot {
            XCTAssertNotEqual(DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud), .available,
                              "precondition: iCloud Drive is closed to new albums")

            let album = try seedLegacyAlbum()
            defer { cleanup(album) }
            let (backend, _) = await backend(for: album)

            let original = tinyPNG()
            let id = UUID().uuidString
            let saved = try await backend.save(media: try makePhoto(id: id), metadata: nil, progress: { _ in })

            let encrypted = try XCTUnwrap(saved, "saving into an existing iCloud Drive album must succeed")
            let url = try XCTUnwrap(encrypted.underlyingMedia.first?.url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "the ciphertext must actually land on disk")
            XCTAssertTrue(url.path.hasPrefix(iCloudStorageModel.rootURL.path),
                          "and must land inside the iCloud Drive container, not be diverted to local storage")

            let listed: [InteractableMedia<EncryptedMedia>] = await backend.enumerateMedia()
            XCTAssertTrue(listed.contains { $0.id == id },
                          "newly added media must be enumerable from the legacy album")

            let loaded = try await backend.loadMedia(media: encrypted, progress: { _ in })
            let cleartext = try XCTUnwrap(loaded.underlyingMedia.first)
            guard case .data(let bytes) = cleartext.source else {
                return XCTFail("expected in-memory cleartext, got \(cleartext.source)")
            }
            XCTAssertEqual(bytes, original, "and must decrypt back to exactly what was saved")
        }
    }

    /// Deleting media out of a legacy album is equally an operation on data that
    /// already exists, and equally must not be gated on availability.
    func testCanDeleteMediaFromExistingICloudDriveAlbum() async throws {
        try await withICloudDriveRoot {
            let album = try seedLegacyAlbum()
            defer { cleanup(album) }
            let (backend, _) = await backend(for: album)

            let id = UUID().uuidString
            let saved = try await backend.save(media: try makePhoto(id: id), metadata: nil, progress: { _ in })
            let encrypted = try XCTUnwrap(saved)
            let url = try XCTUnwrap(encrypted.underlyingMedia.first?.url)

            try await backend.delete(media: [encrypted])

            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "the ciphertext must be removed from the iCloud Drive container")
            let remaining: [InteractableMedia<EncryptedMedia>] = await backend.enumerateMedia()
            XCTAssertFalse(remaining.contains { $0.id == id },
                           "and must disappear from enumeration")
        }
    }

    // MARK: - Allowed: the album and its contents stay visible

    /// Covers the enumeration and media-count halves of the contract together:
    /// the album keeps appearing in the grid with its real storage type, and its
    /// media keeps being counted. `totalStoredMediaCount` sweeps every storage
    /// type it considers readable — if that ever asked the availability question
    /// instead, a user's legacy photos would stop being counted at all.
    func testExistingICloudDriveAlbumIsEnumerated() async throws {
        try await withICloudDriveRoot {
            XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available,
                           "a substituted container stands in for the ubiquity token")

            let album = try seedLegacyAlbum()
            defer { cleanup(album) }
            let (backend, albumManager) = await backend(for: album)

            _ = try await backend.save(media: try makePhoto(), metadata: nil, progress: { _ in })

            let manager = AlbumManager(keyManager: albumManager.keyManager, syncedDataStore: nil)
            let found = manager.fetchAlbumsFromSources(includingHidden: true)
            let match = try XCTUnwrap(found.first { $0.name == album.name },
                                      "an existing iCloud Drive album must still appear in the grid")
            XCTAssertEqual(match.storageOption, .icloud,
                           "and must keep its real storage type, so the migration prompt can find it")

            let count = await backend.totalStoredMediaCount()
            XCTAssertGreaterThan(count, 0, "media in a legacy album must still be counted")
        }
    }

    // MARK: - Rejected: never offered as a destination

    /// Both halves of "never offered": the predicate itself, and the list every
    /// storage picker in the app renders from (`storageAvailabilities()`, filtered
    /// to `.available`). Asserting only the predicate would miss a picker that
    /// stopped consulting it.
    func testICloudDriveIsNeverOfferedAsAStorageChoice() {
        guard case .unavailable = DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud) else {
            return XCTFail("iCloud Drive must never be offered as a destination for new albums")
        }

        let offered = DataStorageAvailabilityUtil.storageAvailabilities()
            .filter { $0.availability == .available }
            .map(\.storageType)
        XCTAssertFalse(offered.contains(.icloud),
                       "iCloud Drive must be absent from the list the storage pickers render")
        XCTAssertNotEqual(DataStorageAvailabilityUtil.preselectedStorageSetting?.storageType, .icloud,
                          "and must never be the preselected default")
    }
}
