//
//  CloudKitMigrationManagerTests.swift
//  EncameraCoreTests
//
//  Planning coverage for the local -> CloudKit migration engine: every component
//  becomes a stable, deterministically-named work item; re-planning is idempotent
//  and preserves progress; `.cloudKit` albums are rejected (local-only safety).
//

import XCTest
import UIKit
import CloudKit
import Combine
@testable import EncameraCore

@MainActor
final class CloudKitMigrationManagerTests: XCTestCase {

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeAlbum(storage: StorageType = .local) -> Album {
        let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        return Album(name: "mig-\(UUID().uuidString)", storageOption: storage, creationDate: Date(), key: key,
                     albumID: storage == .cloudKit ? UUID().uuidString : nil)
    }

    private func makeManager(for album: Album) -> (CloudKitMigrationManager, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        return (CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store }), albumManager)
    }

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

    /// Lays down `count` real encrypted photos in a fresh local album and returns it.
    private func seedLocalAlbum(count: Int, albumManager: AlbumManaging, album: Album) async throws -> [String] {
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        var ids: [String] = []
        for _ in 0..<count {
            let id = UUID().uuidString
            _ = try await backend.save(media: try makePhoto(id: id), metadata: nil, progress: { _ in })
            ids.append(id)
        }
        return ids
    }

    private func makeExecutableManager(for album: Album) -> (CloudKitMigrationManager, MockAlbumManager, MockCloudKitMediaStore) {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = MockCloudKitMediaStore()
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store })
        return (manager, albumManager, store)
    }

    private func sourceEncURL(album: Album, id: String) -> URL {
        album.storageOption.modelForType.init(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func cleanup(_ album: Album) {
        let model = album.storageOption.modelForType.init(album: album)
        try? FileManager.default.removeItem(at: model.baseURL)
        try? FileManager.default.removeItem(at: MigrationPlanStore.planURL(for: album))
        if let markerID = CloudKitAlbumMarker.albumID(matching: album) {
            try? CloudKitAlbumMarker.remove(albumID: markerID)
        }
        try? MediaIndexStore.clearAllIndexes()
    }

    // MARK: - merge (pure)

    func testMergePreservesProgressResetsFailedKeepsDeletedAndAbsentInProgress() {
        let a = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .verified)
        let b = MigrationItem(mediaID: "b", recordName: "b#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .failed, lastError: "boom")
        let c = MigrationItem(mediaID: "c", recordName: "c#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .sourceDeleted)
        let d = MigrationItem(mediaID: "d", recordName: "d#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: .uploading)

        let freshA = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: Date(), sizeBytes: 99)
        let freshB = MigrationItem(mediaID: "b", recordName: "b#0", mediaType: .photo, createdAt: Date(), sizeBytes: 99)
        let freshE = MigrationItem(mediaID: "e", recordName: "e#0", mediaType: .photo, createdAt: Date(), sizeBytes: 99)

        let merged = CloudKitMigrationManager.merge(existing: [a, b, c, d], enumerated: [freshA, freshB, freshE])
        let byRecord = Dictionary(uniqueKeysWithValues: merged.map { ($0.recordName, $0) })

        XCTAssertEqual(byRecord["a#0"]?.state, .verified, "in-progress/verified items keep their state")
        XCTAssertEqual(byRecord["a#0"]?.sizeBytes, 10, "preserved items keep their prior fields")
        XCTAssertEqual(byRecord["b#0"]?.state, .pending, "a failed item is reset to pending so it retries")
        XCTAssertEqual(byRecord["b#0"]?.sizeBytes, 99, "and refreshed with the current size")
        XCTAssertEqual(byRecord["e#0"]?.state, .pending, "a newly-seen file becomes a pending item")
        XCTAssertEqual(byRecord["c#0"]?.state, .sourceDeleted, "a completed item absent from disk is preserved")
        XCTAssertEqual(byRecord["d#0"]?.state, .uploading,
                       "an in-progress item absent from disk is preserved, not dropped, so its CloudKit progress isn't lost")
        XCTAssertEqual(merged.count, 5)
    }

    // MARK: - Local-only safety

    func testPlanRejectsCloudKitAlbum() async throws {
        let album = makeAlbum(storage: .cloudKit)
        let (manager, _) = makeManager(for: album)
        do {
            _ = try await manager.plan(album: album)
            XCTFail("a .cloudKit album must not be planned for migration")
        } catch MigrationError.invalidSourceStorage(let storage) {
            XCTAssertEqual(storage, .cloudKit)
        }
    }

    // MARK: - Planning

    func testPlanCreatesPendingItemPerComponent() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
        let plan = try await manager.plan(album: album)

        XCTAssertEqual(plan.items.count, 3)
        XCTAssertEqual(Set(plan.items.map(\.mediaID)), Set(ids))
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .pending })
        XCTAssertTrue(plan.items.allSatisfy { $0.sizeBytes > 0 }, "size is read from the on-disk ciphertext")
        XCTAssertTrue(plan.items.allSatisfy { $0.recordName == "\($0.mediaID)#\(MediaType.photo.rawValue)" })
        XCTAssertEqual(plan.source.storage, .local)
        XCTAssertEqual(manager.progress.totalCount, 3)
    }

    func testStableMediaIDsAndRecordNamesAcrossReplan() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let first = try await manager.plan(album: album)
        let second = try await manager.plan(album: album)

        XCTAssertEqual(Set(first.items.map(\.mediaID)), Set(ids),
                       "the plans being compared must cover every seeded component")
        XCTAssertEqual(first.items.map(\.recordName).sorted(), second.items.map(\.recordName).sorted())
        XCTAssertEqual(first.items.map(\.mediaID).sorted(), second.items.map(\.mediaID).sorted())
    }

    func testReplanPreservesProgressedItems() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        let store = MigrationPlanStore(album: album)
        let loaded = await store.load()
        var persisted = try XCTUnwrap(loaded)
        let verifiedRecord = persisted.items[0].recordName
        persisted.items[0].state = .verified
        try await store.save(persisted)

        let replanned = try await manager.plan(album: album)
        let item = try XCTUnwrap(replanned.items.first { $0.recordName == verifiedRecord })
        XCTAssertEqual(item.state, .verified, "re-planning must not undo work already done")
    }

    func testPlanPersistsEncryptedToDisk() async throws {
        let album = makeAlbum()
        let (manager, albumManager) = makeManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        XCTAssertTrue(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path))
        let reloaded = await MigrationPlanStore(album: album).load()
        XCTAssertEqual(reloaded?.items.count, 1)

        let raw = try Data(contentsOf: MigrationPlanStore.planURL(for: album))
        XCTAssertFalse(raw.isEmpty)
        XCTAssertNil(try? JSONSerialization.jsonObject(with: raw),
                     "the checkpoint must not be readable as plaintext JSON")
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(album.name),
                       "the album name must not be recoverable from the checkpoint on disk")
    }

    // MARK: - Execution

    func testHappyPathUploadsVerifiesAndDeletesSource() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(manager.progress.fractionComplete, 1.0, accuracy: 0.0001)
        XCTAssertEqual(store.uploadCalls.count, 3, "each component uploads exactly once")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the album flips to CloudKit exactly once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path), "the checkpoint is removed on completion")

        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                           "the local original is deleted after a verified upload")
        }
    }

    func testSourceNotDeletedWhenVerifyFails() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = false   // fetchMetadata stays empty -> verify fails
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(store.uploadCalls.count, 2, "items upload...")
        let loaded = await MigrationPlanStore(album: album).load()
        let plan = try XCTUnwrap(loaded)
        XCTAssertTrue(plan.items.allSatisfy { $0.state != .sourceDeleted }, "...but none are deleted without verification")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "the local original survives a failed verification")
        }
        if case .failed = manager.state {} else { XCTFail("expected a failed run, got \(manager.state)") }
    }

    func testMigrationPreservesPreviewsInGlobalThumbnailDirectory() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let model = album.storageOption.modelForType.init(album: album)
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.previewURLForMedia(withID: id).path),
                          "precondition: seeding produced a preview")
        }

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.previewURLForMedia(withID: id).path),
                          "the preview survives the move — the migrated album reads it from the same global path")
            try? FileManager.default.removeItem(at: model.previewURLForMedia(withID: id))
        }
    }

    func testReRunAfterCompletionDoesNotReUpload() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)
        XCTAssertEqual(store.uploadCalls.count, 2)
        XCTAssertEqual(albumManager.finalizeCallCount, 1)

        await manager.start(album: album)
        XCTAssertEqual(store.uploadCalls.count, 2, "completed items are never re-uploaded")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the album is not re-finalized")
    }

    func testResumingAnAlreadyUploadedItemVerifiesWithoutReUploading() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        let id = try XCTUnwrap(ids.first)
        let planned = try await manager.plan(album: album)
        let item = try XCTUnwrap(planned.items.first)

        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: try XCTUnwrap(planned.destination.cloudKitAlbumID), mediaID: item.mediaID, mediaType: item.mediaType,
            createdAt: item.createdAt, sizeBytes: item.sizeBytes, creationDeviceID: "mock",
            schemaVersion: 1, recordChangeTag: "tag"
        )]
        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        persisted.items[0].state = .uploaded
        try await planStore.save(persisted)

        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "an already-uploaded item is verified, not re-uploaded")
        XCTAssertEqual(manager.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
    }

    /// An album checkpoint whose one item is in `state`, with its record in the
    /// destination album and since moved to another album from another device.
    private func runAlbumResumedWithItsRecordMovedToAnotherAlbum(state: MigrationItemState,
                                                                  file: StaticString = #filePath,
                                                                  line: UInt = #line) async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }
        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        let id = try XCTUnwrap(ids.first)
        let planned = try await manager.plan(album: album)
        let item = try XCTUnwrap(planned.items.first)
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: try XCTUnwrap(planned.destination.cloudKitAlbumID),
            mediaID: item.mediaID, mediaType: item.mediaType, createdAt: item.createdAt,
            sizeBytes: item.sizeBytes, creationDeviceID: "mock", schemaVersion: 1, recordChangeTag: "tag")]
        _ = try await store.reassignAlbum(recordNames: [item.recordName], toAlbumID: "another-album")
        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        persisted.items[0].state = state
        try await planStore.save(persisted)

        await manager.start(album: album)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                      "a record now in another album is not this move's copy, so the local original stays",
                      file: file, line: line)
        XCTAssertTrue(store.uploadCalls.isEmpty, "the other album's record is never saved over", file: file, line: line)
        let owner = try await store.confirmAlbum(recordName: item.recordName)
        XCTAssertEqual(owner, "another-album", file: file, line: line)
        XCTAssertEqual(manager.state, .completed, "the item is skipped, which is terminal", file: file, line: line)
    }

    func testResumingAnUploadedItemWhoseRecordWasMovedToAnotherAlbumKeepsTheLocalOriginal() async throws {
        try await runAlbumResumedWithItsRecordMovedToAnotherAlbum(state: .uploaded)
    }

    func testResumingAStaleVerifiedItemWhoseRecordWasMovedToAnotherAlbumKeepsTheLocalOriginal() async throws {
        try await runAlbumResumedWithItsRecordMovedToAnotherAlbum(state: .verified)
    }

    // MARK: - Parent reference ordering

    func testAlbumRecordIsSavedBeforeAnyUpload() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.enforceParentAlbumExists = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(store.savedAlbumCalls.count, 1, "the album record is created up front, before the item loop")
        XCTAssertEqual(manager.state, .completed,
                       "uploads succeed because the parent album record already exists on the server")
        XCTAssertEqual(store.uploadCalls.count, 2)
    }

    // MARK: - Key fingerprint

    func testMigratedMediaIsStampedWithTheAlbumKeyFingerprint() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadedItems.count, 2)
        for upload in store.uploadedItems {
            XCTAssertEqual(upload.keyFingerprint, album.key.keychainLabel,
                           "every migrated record must name the key that encrypted it")
        }
        XCTAssertEqual(store.savedAlbumCalls.first?.keyFingerprint, album.key.keychainLabel,
                       "and the album record agrees with its media")
        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 2, fingerprints: [album.key.keychainLabel: 2]),
                       "so the census can name the key for the whole migrated library")
    }

    func testSaveAlbumFailureFailsFastWithoutUploading() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.saveAlbumError = CloudKitMediaStoreError.zoneNotFound
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "no uploads are attempted without the parent album record")
        guard case .failed(.other) = manager.state else {
            return XCTFail("expected a failed run carrying the saveAlbum error, got \(manager.state)")
        }
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "nothing is deleted when the run fails before uploading")
        }
    }

    func testSaveAlbumSchemaMissingSurfacesSchemaNotDeployedReason() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        let serverError = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.invalidArguments.rawValue,
            userInfo: ["ServerErrorDescription": "Cannot create new type EncAlbum in production schema"]
        )
        store.saveAlbumError = CloudKitMediaStoreError.partial(failed: ["albumhash": serverError])
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "no uploads are attempted without the parent album record")
        XCTAssertEqual(manager.state, .failed(.schemaNotDeployed))
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "nothing is deleted when the run fails before uploading")
        }
    }

    // MARK: - Errors, pause, cancel

    func testRetryAfterBacksOffThenSucceeds() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.retry(after: 0)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadCalls.count, 2, "one retried attempt then a success")
    }

    func testQuotaExceededHaltsThenResumeCompletes() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.quotaExceeded
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.quota), "quota is non-retryable: the run halts, recoverable")
        let midLoaded = await MigrationPlanStore(album: album).load()
        let mid = try XCTUnwrap(midLoaded)
        XCTAssertFalse(mid.items.contains { $0.state == .sourceDeleted }, "nothing deleted while halted")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
        }

        await manager.resume(album: album)
        XCTAssertEqual(manager.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path), "the checkpoint is removed on completion")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
        }
    }

    func testQuotaWrappedInPartialFailureStillHaltsAsQuota() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.partial(
            failed: ["some-record": CKErrorFactory.error(.quotaExceeded)]
        )
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.quota), "a partial-wrapped quota failure must halt as quota")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
        }
    }

    func testConflictWrappedInPartialFallsThroughToVerify() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        let plan = try await manager.plan(album: album)
        let item = try XCTUnwrap(plan.items.first)
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName,
            albumID: try XCTUnwrap(plan.destination.cloudKitAlbumID),
            mediaID: item.mediaID,
            mediaType: item.mediaType,
            createdAt: item.createdAt,
            sizeBytes: item.sizeBytes,
            creationDeviceID: "other-device",
            schemaVersion: CloudKitSchema.currentSchemaVersion,
            recordChangeTag: "tag-existing"
        )]
        store.uploadErrorOnce = CloudKitMediaStoreError.partial(
            failed: [item.recordName: CKErrorFactory.error(.serverRecordChanged)]
        )

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "an already-on-server record must verify and complete, not wedge as failed")
    }

    func testStaleVerifiedItemIsReVerifiedBeforeSourceDelete() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        var plan = try await manager.plan(album: album)
        for index in plan.items.indices { plan.items[index].state = .verified }
        try await MigrationPlanStore(album: album).save(plan)

        await manager.start(album: album)

        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "a stale verification must never justify deleting the local original")
        }
        let reloadedPlan = await MigrationPlanStore(album: album).load()
        let reloaded = try XCTUnwrap(reloadedPlan)
        XCTAssertTrue(reloaded.items.allSatisfy { $0.state == .failed },
                      "an item that cannot re-verify is failed (resumable: re-plan resets failed to pending)")
        guard case .failed = manager.state else {
            return XCTFail("expected a visible .failed run, got \(manager.state)")
        }
    }

    func testStaleVerifiedItemIsReDrivenToCompletionInSamePass() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        var plan = try await manager.plan(album: album)
        for index in plan.items.indices { plan.items[index].state = .verified }
        try await MigrationPlanStore(album: album).save(plan)

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "the re-driven item must finish in this pass")
        XCTAssertEqual(store.uploadCalls.count, 1, "the vanished record is re-uploaded exactly once")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                           "the source is deleted only after the fresh upload re-verified")
        }
    }

    func testUnwrapPartialUnwrapsSingleAndHomogeneousErrors() {
        let single = CloudKitMigrationManager.unwrapPartial(
            .partial(failed: ["r1": CKErrorFactory.error(.quotaExceeded)])
        )
        guard case .quotaExceeded = single else { return XCTFail("single-record partial must unwrap, got \(single)") }

        let homogeneous = CloudKitMigrationManager.unwrapPartial(
            .partial(failed: ["r1": CKErrorFactory.error(.quotaExceeded),
                              "r2": CKErrorFactory.error(.quotaExceeded)])
        )
        guard case .quotaExceeded = homogeneous else { return XCTFail("homogeneous partial must unwrap, got \(homogeneous)") }

        let mixed = CloudKitMigrationManager.unwrapPartial(
            .partial(failed: ["r1": CKErrorFactory.error(.quotaExceeded),
                              "r2": CKErrorFactory.error(.serverRecordChanged)])
        )
        guard case .partial = mixed else { return XCTFail("heterogeneous partial must stay partial, got \(mixed)") }
    }

    /// Offline, the server's albums cannot be listed, and minting an id anyway would
    /// split the album from the one another device may already have moved it into.
    func testMigrationFailsClosedWhenTheDestinationAlbumCannotBeLookedUp() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.fetchAllAlbumsError = CloudKitMediaStoreError.underlying(NSError(domain: NSURLErrorDomain,
                                                                              code: NSURLErrorNotConnectedToInternet))
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        guard case .failed(.other) = manager.state else {
            return XCTFail("expected the run to fail closed, got \(manager.state)")
        }
        XCTAssertEqual(store.fetchAllAlbumsCount, 1, "the failure comes from the album lookup")
        let persisted = await MigrationPlanStore(album: album).load()
        XCTAssertNil(persisted, "no plan is written without a destination album")
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "no album record is written under a guessed id")
        XCTAssertTrue(store.uploadCalls.isEmpty, "no media is uploaded under a guessed id")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "nothing is deleted when the run fails before uploading")
        }
    }

    func testAccountUnavailableFailsRunWithoutUploading() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.accountAvailableValue = false
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.accountUnavailable))
        XCTAssertTrue(store.uploadCalls.isEmpty, "no uploads are attempted without an account")
    }

    func testCancelRevertsInFlightItemAndStaysUsable() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        persisted.items[0].state = .uploading
        try await planStore.save(persisted)

        await manager.cancel(album: album)

        XCTAssertEqual(manager.state, .idle)
        let revertedLoad = await planStore.load()
        let reverted = try XCTUnwrap(revertedLoad)
        XCTAssertEqual(reverted.items[0].state, .pending, "an in-flight item is reverted so a resume re-drives it")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "cancel never deletes a source file")
        }
    }

    func testCancelIsDurableAndNotAutoResumed() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)
        let pendingBeforeCancel = await manager.pendingPlans()
        XCTAssertEqual(pendingBeforeCancel.map(\.source.albumID), [album.id],
                       "an incomplete plan is resumable before it is cancelled")

        await manager.cancel(album: album)

        let persisted = await MigrationPlanStore(album: album).load()
        XCTAssertNotNil(persisted?.cancelledAt, "an explicit cancel is recorded durably on the checkpoint")
        let pendingAfterCancel = await manager.pendingPlans()
        XCTAssertTrue(pendingAfterCancel.isEmpty,
                      "a cancelled migration is never silently auto-resumed on the next launch")
    }

    func testCancelDuringPreflightIsHonoredBeforeAnyUpload() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        store.accountAvailableGate = { [weak manager] in
            await manager?.cancel(album: album)
        }
        await manager.start(album: album)

        XCTAssertTrue(store.uploadCalls.isEmpty, "no upload may start after an explicit cancel")
        XCTAssertEqual(manager.state, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: ids[0]).path),
                      "the local original is untouched")
        let plan = await MigrationPlanStore(album: album).load()
        XCTAssertNotNil(plan?.cancelledAt, "the cancel must be durable so background auto-resume skips it")
    }

    func testCancelDuringPreflightOfEmptyAlbumDoesNotFinalize() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 0, albumManager: albumManager, album: album)
        store.accountAvailableGate = { [weak manager] in
            await manager?.cancel(album: album)
        }
        await manager.start(album: album)

        XCTAssertEqual(store.ensureZoneCalls, 1, "the run must have reached the preflight the cancel lands in")
        let persisted = await MigrationPlanStore(album: album).load()
        XCTAssertNotNil(persisted?.cancelledAt, "the cancel, not an unrelated abort, must be what stopped the run")
        XCTAssertEqual(albumManager.finalizeCallCount, 0,
                       "an explicit cancel must not flip the album to CloudKit")
        XCTAssertEqual(manager.state, .idle)
    }

    func testMissingSourceFileDoesNotWedgeMigration() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)
        try FileManager.default.removeItem(at: sourceEncURL(album: album, id: ids[0]))

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed,
                       "a single missing file must not block the album short of completion")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the album still flips to CloudKit")
        XCTAssertEqual(store.uploadCalls.count, 1, "only the file that still exists is uploaded")
    }

    func testEmptyAlbumMigrationFinalizesAndCompletes() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 0, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "an empty album must complete, not wedge as .idle")
        XCTAssertEqual(albumManager.finalizeCallCount, 1, "the empty album still flips to CloudKit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path), "no orphaned zero-item checkpoint is left behind")
        XCTAssertTrue(store.uploadCalls.isEmpty)
    }

    func testPlanDoesNotPublishTerminalCompleted() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        let planStore = MigrationPlanStore(album: album)
        let loaded = await planStore.load()
        var persisted = try XCTUnwrap(loaded)
        for index in persisted.items.indices { persisted.items[index].state = .sourceDeleted }
        try await planStore.save(persisted)

        _ = try await manager.plan(album: album)
        XCTAssertEqual(manager.progress.verifiedCount, 1,
                       "precondition: the re-plan observed the all-terminal checkpoint")
        XCTAssertEqual(manager.state, .idle,
                       "plan() must leave terminal states to run()")
    }

    // MARK: - Estimate (pre-flight)

    func testEstimateReturnsCountsWithoutPersistingCheckpoint() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let estimate = await manager.estimate(album: album)

        XCTAssertEqual(estimate.itemCount, 2)
        XCTAssertGreaterThan(estimate.totalBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path),
                       "previewing the estimate must not leave a checkpoint that could auto-resume")
    }

    func testEstimateIsZeroForCloudKitAlbum() async throws {
        let album = makeAlbum(storage: .cloudKit)
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)

        let estimate = await manager.estimate(album: album)
        XCTAssertEqual(estimate.itemCount, 0)
        XCTAssertEqual(estimate.totalBytes, 0)
    }

    // MARK: - Launch-time resume

    func testPendingPlansSurfacesIncompleteMigration() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)

        let pending = await manager.pendingPlans()
        XCTAssertEqual(pending.map(\.source.albumID), [album.id])
    }

    func testPendingPlansEmptyWhenNoCheckpoint() async throws {
        let album = makeAlbum()
        let (manager, albumManager, _) = makeExecutableManager(for: album)
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)
        let pendingWithCheckpoint = await manager.pendingPlans()
        XCTAssertEqual(pendingWithCheckpoint.map(\.source.albumID), [album.id],
                       "precondition: the album is reachable by the enumeration while a checkpoint exists")

        await MigrationPlanStore(album: album).delete()

        let pending = await manager.pendingPlans()
        XCTAssertTrue(pending.isEmpty)
    }

    func testFinalizeFailureKeepsCheckpointSurfacedByPendingPlans() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        albumManager.albumsOnDisk = [album]
        albumManager.finalizeError = AlbumError.cloudKitMarkerWriteFailed
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        guard case .failed = manager.state else {
            return XCTFail("finalize failure must fail the run, got \(manager.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path), "the checkpoint is kept for retry")

        let pending = await manager.pendingPlans()
        XCTAssertEqual(pending.map(\.source.albumID), [album.id],
                       "a finalize-pending checkpoint has no remaining per-item work, but it IS unfinished business")
    }

    func testFinalizeFailureCheckpointResumesToCompletion() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        albumManager.albumsOnDisk = [album]
        albumManager.finalizeError = AlbumError.cloudKitMarkerWriteFailed
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)
        albumManager.finalizeError = nil

        await manager.resume(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(albumManager.finalizeCallCount, 2, "the resume retried finalize")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path), "completion deletes the checkpoint")
        XCTAssertEqual(store.uploadCalls.count, 1, "the resume must not re-upload the already-verified item")
    }

    func testPendingPlansEmptyAfterCompletion() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        albumManager.albumsOnDisk = [album]
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        _ = try await manager.plan(album: album)
        let pendingBeforeRun = await manager.pendingPlans()
        XCTAssertEqual(pendingBeforeRun.map(\.source.albumID), [album.id],
                       "precondition: the checkpoint is resumable until a run finishes it")

        await manager.start(album: album)
        XCTAssertEqual(manager.state, .completed, "precondition: the migration actually completed")

        let pending = await manager.pendingPlans()
        XCTAssertTrue(pending.isEmpty, "a completed migration leaves no checkpoint to resume")
    }

    // MARK: - AlbumManager integration

    func testMoveAlbumToCloudKitIsRejectedInFavorOfMigration() async throws {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let album = makeAlbum()
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        do {
            _ = try await manager.moveAlbum(album: album, toStorage: .cloudKit)
            XCTFail("expected migrationRequiredForCloudKit")
        } catch AlbumError.migrationRequiredForCloudKit {
        } catch {
            XCTFail("expected migrationRequiredForCloudKit, got \(error)")
        }
    }

    /// Moving media into the cloud must never be treated as consent to sync the
    /// key that decrypts it. A full local -> CloudKit migration leaves the key
    /// sync setting exactly as the user left it.
    func testMigrationDoesNotTouchKeySyncSetting() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        let keyManager = albumManager.keyManager as! DemoKeyManager
        keyManager.isSyncEnabled = false

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "precondition: the migration actually ran")
        XCTAssertFalse(keyManager.isSyncEnabled, "a migration must not enable key sync as a side effect")
    }

    func testFinalizeWritesDiscoveryMarkerAndRemovesSource() throws {
        // Finalize pushes the album record via the global store provider, and with
        // `cloudKitStorage` defaulting ON in DEBUG the real provider constructs a
        // live CKContainer — which aborts the bare xctest process (no CloudKit
        // entitlement). Bind the in-memory mock for the duration of this test.
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in InMemoryCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let albumID = UUID().uuidString
        let result = try manager.finalizeMigrationToCloudKit(album: album, albumID: albumID)
        defer { try? CloudKitAlbumMarker.remove(albumID: albumID) }

        XCTAssertEqual(result.storageOption, .cloudKit)
        XCTAssertEqual(result.albumID, albumID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.baseURL.path), "the drained source dir is removed")
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID), "the CloudKit discovery marker is written")
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: album.key), album.name)
    }

    // MARK: - iCloud Drive deprecation is unconditional

    func testCreateICloudDriveAlbumThrowsInAllBuildConfigurations() throws {
        let prior = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: prior) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        XCTAssertThrowsError(
            try manager.create(name: "drive-\(UUID().uuidString)", storageOption: .icloud)
        ) { error in
            guard case AlbumError.iCloudDriveDeprecated = error else {
                return XCTFail("expected iCloudDriveDeprecated, got \(error)")
            }
        }
    }

    func testMoveToICloudDriveThrowsInAllBuildConfigurations() async throws {
        let prior = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: prior) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let album = makeAlbum()
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        defer { cleanup(album) }

        do {
            _ = try await manager.moveAlbum(album: album, toStorage: .icloud)
            XCTFail("expected iCloudDriveDeprecated")
        } catch AlbumError.iCloudDriveDeprecated {
        } catch {
            XCTFail("expected iCloudDriveDeprecated, got \(error)")
        }
    }

    /// The deprecation must not hand a `.icloud` default back to the picker-less
    /// quick-create paths, which would walk straight into the create backstop.
    func testPersistedICloudDefaultIsCoercedToLocal() throws {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let prior = manager.defaultStorageForAlbum
        defer { manager.defaultStorageForAlbum = prior }

        manager.defaultStorageForAlbum = .icloud
        XCTAssertEqual(manager.defaultStorageForAlbum, .local)
    }

    /// Deprecation must stop iCloud Drive being OFFERED, never stop what is already
    /// there being SEEN. If enumeration were gated on `isStorageTypeOfferedForNewAlbums`
    /// (which reports `.icloud` unavailable unconditionally) instead of
    /// `isStorageTypeAvailable`, a user's existing Drive albums would silently vanish
    /// from the grid — unusable and unmigratable, since the migration prompt can only
    /// offer what it can find.
    func testICloudDriveAlbumsRemainEnumerableWhileDeprecated() async throws {
        XCTAssertNotEqual(DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud), .available,
                          "precondition: iCloud Drive is never offered as a destination")

        try await withICloudDriveRoot {
            XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available,
                           "but an existing container is still readable")

            let keyManager = DemoKeyManager()
            let key = PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
            keyManager.currentKey = key
            let manager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

            let legacy = Album(name: "legacy-\(UUID().uuidString)", storageOption: .icloud,
                               creationDate: Date(), key: key)
            try iCloudStorageModel(album: legacy).initializeDirectories()
            defer { cleanup(legacy) }

            let found = manager.fetchAlbumsFromSources(includingHidden: true)
            let match = try XCTUnwrap(found.first { $0.name == legacy.name },
                                      "an existing iCloud Drive album must still appear in the grid")
            XCTAssertEqual(match.storageOption, .icloud,
                           "and must keep its real storage type, so the migration prompt can find it")
        }
    }

    // MARK: - iCloud Drive (legacy) source

    /// Points `iCloudStorageModel` at a scratch directory for the duration of a test.
    /// Neither the simulator nor a unit-test host has a ubiquity container, so without
    /// this the `.icloud` source path cannot be executed at all — `rootURL` traps.
    /// Everything downstream of `albumManager.storageModel(for:)` is unchanged, and
    /// that single seam is what the engine drives the source through, so these tests
    /// exercise the real `.icloud` code path rather than a re-labelled local one.
    private func withICloudDriveRoot(_ body: () async throws -> Void) async rethrows {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("icloud-drive-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = root
        defer {
            iCloudStorageModel.testContainerRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    /// Planning must enumerate a legacy iCloud Drive album exactly as it does a local
    /// one — the engine accepts `.icloud`, but until now only `.local` had ever been
    /// executed end to end.
    func testPlanFromICloudDriveSourceEnumeratesAllItems() async throws {
        try await withICloudDriveRoot {
            let album = makeAlbum(storage: .icloud)
            let (manager, albumManager) = makeManager(for: album)
            defer { cleanup(album) }

            let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
            let plan = try await manager.plan(album: album)

            XCTAssertEqual(plan.source.storage, .icloud)
            XCTAssertEqual(plan.items.count, 3, "every component of an iCloud Drive album becomes a work item")
            XCTAssertEqual(Set(plan.items.map(\.mediaID)), Set(ids))
            XCTAssertTrue(plan.items.allSatisfy { $0.state == .pending })
            XCTAssertTrue(plan.items.allSatisfy { $0.sizeBytes > 0 },
                          "sizes are read from the iCloud Drive container, not assumed")
        }
    }

    /// The verification gate must hold for an iCloud Drive source too: if the record
    /// cannot be confirmed in CloudKit, the Drive original is never removed. This is
    /// the only copy of the user's data at that moment, so a source-agnostic delete
    /// would be silent data loss.
    func testICloudDriveSourceRemovedOnlyAfterVerification() async throws {
        try await withICloudDriveRoot {
            let album = makeAlbum(storage: .icloud)
            let (manager, albumManager, store) = makeExecutableManager(for: album)
            store.reflectUploadsInMetadata = false   // verification can never succeed
            defer { cleanup(album) }

            let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
            await manager.start(album: album)

            XCTAssertEqual(store.uploadCalls.count, 2, "items upload...")
            let loaded = await MigrationPlanStore(album: album).load()
            let plan = try XCTUnwrap(loaded)
            XCTAssertTrue(plan.items.allSatisfy { $0.state != .sourceDeleted },
                          "...but no item advances past verification")
            for id in ids {
                XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                              "the iCloud Drive original survives a failed verification")
            }
            XCTAssertEqual(albumManager.finalizeCallCount, 0, "and the album is not flipped to CloudKit")
            if case .failed = manager.state {} else { XCTFail("expected a failed run, got \(manager.state)") }

            store.reflectUploadsInMetadata = true
            await manager.start(album: album)

            XCTAssertEqual(manager.state, .completed)
            for id in ids {
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                               "once verified, the iCloud Drive original is removed")
            }
        }
    }

    /// A migration killed mid-flight resumes from its checkpoint on the next launch,
    /// mirroring the existing `.local` resume coverage.
    func testInterruptedICloudDriveMigrationResumes() async throws {
        try await withICloudDriveRoot {
            let album = makeAlbum(storage: .icloud)
            let (manager, albumManager, store) = makeExecutableManager(for: album)
            albumManager.albumsOnDisk = [album]
            store.reflectUploadsInMetadata = true
            defer { cleanup(album) }

            let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
            let planned = try await manager.plan(album: album)
            XCTAssertEqual(planned.items.count, 2)

            let planStore = MigrationPlanStore(album: album)
            let loaded = await planStore.load()
            var persisted = try XCTUnwrap(loaded)
            persisted.items[0].state = .sourceDeleted
            try await planStore.save(persisted)
            try FileManager.default.removeItem(at: sourceEncURL(album: album, id: persisted.items[0].mediaID))

            let pending = await manager.pendingPlans()
            XCTAssertEqual(pending.map(\.source.albumID), [album.id],
                           "the interrupted iCloud Drive migration is surfaced for resume on launch")

            await manager.start(album: album)

            XCTAssertEqual(manager.state, .completed)
            XCTAssertEqual(store.uploadCalls.count, 1,
                           "only the item that had not finished is uploaded on resume")
            XCTAssertEqual(albumManager.finalizeCallCount, 1)
            for id in ids {
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: album).path), "the checkpoint is cleared on completion")
        }
    }

    // MARK: - Published phase

    /// Records every `progress` snapshot published while `body` runs. Everything here
    /// is main-actor isolated and the run is awaited, so the sink fires synchronously
    /// on each assignment and the recorded order is the published order.
    private func recordingProgress(
        of manager: CloudKitMigrationManager,
        during body: () async -> Void
    ) async -> [MigrationProgress] {
        var seen: [MigrationProgress] = []
        let subscription = manager.$progress.sink { seen.append($0) }
        await body()
        subscription.cancel()
        return seen
    }

    func testPhaseAdvancesUploadingVerifyingRemovingAcrossOneItem() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)

        let seen = await recordingProgress(of: manager) { await manager.start(album: album) }
        XCTAssertEqual(manager.state, .completed)

        let phases = seen.map(\.phase).reduce(into: [MigrationPhase?]()) { acc, phase in
            if acc.last != phase { acc.append(phase) }
        }

        XCTAssertEqual(phases.compactMap { $0 },
                       [.preparing, .uploading, .verifying, .removingLocalCopy],
                       "the published phase must walk the item's real transitions in order")
    }

    func testPhasePersistsAcrossTheBetweenItemProgressRepublish() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)

        let seen = await recordingProgress(of: manager) { await manager.start(album: album) }
        XCTAssertEqual(manager.state, .completed)

        let phases = seen.map(\.phase)
        let firstActive = try XCTUnwrap(phases.firstIndex(where: { $0 != nil }))
        let lastActive = try XCTUnwrap(phases.lastIndex(where: { $0 != nil }))

        XCTAssertFalse(phases[firstActive...lastActive].contains(nil),
                       "no nil phase may be published between the first and last active phase — that is the clobber this guards")
    }

    func testPhaseIsClearedOnCompletion() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertNil(manager.progress.phase, "a completed migration must not still claim a phase")
    }

    func testPhaseIsClearedOnCancel() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        store.onUploadStarted = { [weak manager] in
            await manager?.cancel(album: album)
        }

        let seen = await recordingProgress(of: manager) {
            await manager.start(album: album)
        }

        XCTAssertTrue(seen.contains { $0.phase != nil }, "precondition: the run published a phase before the cancel")
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.progress.phase, "a cancelled migration must not still claim a phase")
    }

    func testPhaseIsClearedWhenAQuotaFailureHaltsTheRun() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.quotaExceeded
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        await manager.start(album: album)

        XCTAssertEqual(manager.state, .failed(.quota))
        XCTAssertNil(manager.progress.phase, "a halted migration must not still claim a phase")
    }

    func testRetryingPhaseIsPublishedDuringBackoff() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.retry(after: 0)
        defer { cleanup(album) }

        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)

        let seen = await recordingProgress(of: manager) { await manager.start(album: album) }

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(store.uploadCalls.count, 2, "one retried attempt then a success")
        XCTAssertTrue(seen.contains { $0.phase == .retrying },
                      "a CloudKit-requested backoff must be visible as .retrying, not an unexplained stall")
        XCTAssertNil(manager.progress.phase)
    }

    /// The phase is in-memory only. `MigrationPlan` is a durable on-disk format, and a
    /// phase written into it would be a lie after a crash.
    func testMigrationPlanEncodingIsUnchangedByPhase() throws {
        let plan = try MigrationPlan(
            id: MigrationPlan.albumPlanID,
            source: MigrationEndpoint(albumName: "album", storage: .local),
            destination: MigrationEndpoint(albumName: "album", storage: .cloudKit),
            scope: .album,
            items: [MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: Date(), sizeBytes: 10)],
            createdAt: Date()
        )

        let encoded = try JSONEncoder().encode(plan)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["id", "source", "destination", "scope", "items", "createdAt", "version"],
                       "the checkpoint's key set must not change — `phase` is never persisted")

        let itemObjects = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertFalse(itemObjects.contains { $0.keys.contains("phase") },
                       "items must not carry a phase either")

        let decoded = try JSONDecoder().decode(MigrationPlan.self, from: encoded)
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.version, MigrationPlan.currentVersion)
    }
}

// MARK: - Whole album CloudKit -> local

extension CloudKitMigrationManagerTests {

    private struct ToLocalFixture {
        let manager: CloudKitMigrationManager
        let albumManager: MockAlbumManager
        let store: MockCloudKitMediaStore
        let album: Album
        let local: Album
        let ids: [String]

        var recordNames: [String] { ids.map { CloudKitFileAccess.componentRecordName(mediaID: $0, type: .photo) } }
        var plan: MigrationPlan { try! MigrationPlan.album(album, items: []) }

        func localURL(_ id: String) -> URL {
            LocalStorageModel(album: local).driveURLForMedia(withID: id, type: .photo)
        }
    }

    /// A CloudKit album whose `count` photo records the mock store reports through
    /// its change feed, so the engine's reconcile builds the index the plan comes from.
    private func makeToLocalFixture(count: Int, chunkStore: ChunkedBlobStoring? = nil,
                                    uploadQueue: CloudKitUploadQueue = .shared) throws -> ToLocalFixture {
        let album = makeAlbum(storage: .cloudKit)
        let local = Album.localTwin(of: album)
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]
        let store = MockCloudKitMediaStore()
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store },
                                               chunkStore: chunkStore, uploadQueue: uploadQueue)
        let hash = try XCTUnwrap(album.albumID)
        let ids = (0..<count).map { _ in UUID().uuidString }
        store.changeSet = CloudKitChangeSet(
            changed: ids.map { id in
                CloudKitMediaMetadata(recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                                      albumID: hash, mediaID: id, mediaType: .photo, createdAt: Date(),
                                      sizeBytes: 10, creationDeviceID: "mock", schemaVersion: 1,
                                      recordChangeTag: "tag")
            },
            deleted: [], token: nil, moreComing: false)
        // The same records answer a lookup by name, as they would on the server.
        store.metadataToReturn = store.changeSet.changed
        store.blobContents = Data(repeating: 0xAA, count: 10)
        try CloudKitAlbumMarker(album: album, isHidden: false).write(albumID: hash)
        return ToLocalFixture(manager: manager, albumManager: albumManager, store: store,
                              album: album, local: local, ids: ids)
    }

    private func cleanup(_ fixture: ToLocalFixture) {
        cleanup(fixture.album)
        try? FileManager.default.removeItem(at: LocalStorageModel(album: fixture.local).baseURL)
        try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: fixture.album))
    }

    /// Writes a checkpoint for the fixture with the given per-item states, and the
    /// local copies an earlier run would have left for items past the download.
    private func saveCheckpoint(_ fixture: ToLocalFixture, states: [MigrationItemState],
                                localBytes: Data = Data(repeating: 0xAA, count: 10)) async throws {
        try LocalStorageModel(album: fixture.local).initializeDirectories()
        let items = zip(fixture.ids, states).map { id, state in
            MigrationItem(mediaID: id, recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                          mediaType: .photo, createdAt: Date(), sizeBytes: 10, state: state)
        }
        for item in items where item.state == .uploaded || item.state == .verified {
            try localBytes.write(to: fixture.localURL(item.mediaID))
        }
        try await MigrationPlanStore(album: fixture.album).save(try MigrationPlan.album(fixture.album, items: items))
    }

    private func planFileExists(_ fixture: ToLocalFixture) -> Bool {
        FileManager.default.fileExists(atPath: MigrationPlanStore.planURL(for: fixture.album).path)
    }

    func testAlbumMoveToLocalCopiesEveryItemThenRemovesTheRecordsAndFinalizes() async throws {
        let fixture = try makeToLocalFixture(count: 3)
        defer { cleanup(fixture) }

        let started = await fixture.manager.start(plan: fixture.plan)

        XCTAssertTrue(started)
        XCTAssertEqual(fixture.manager.state, .completed)
        for id in fixture.ids {
            XCTAssertEqual(try Data(contentsOf: fixture.localURL(id)), fixture.store.blobContents,
                           "every record's ciphertext lands byte-for-byte in the local layout")
        }
        XCTAssertEqual(fixture.store.deleteCalls.sorted(), fixture.recordNames.sorted())
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 1)
        XCTAssertFalse(planFileExists(fixture), "completion deletes the checkpoint")
    }

    func testAlbumMoveToLocalDeletesNoRecordBeforeTheLastItemVerifies() async throws {
        let fixture = try makeToLocalFixture(count: 3)
        defer { cleanup(fixture) }
        let fetchesAtFirstDelete = Box<Int?>(nil)
        let store = fixture.store
        store.onDelete = { _ in
            if fetchesAtFirstDelete.value == nil { fetchesAtFirstDelete.value = store.fetchBlobCount }
        }

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(fetchesAtFirstDelete.value, 3,
                       "every item is downloaded and verified before the first record is deleted")
    }

    func testAlbumMoveToLocalRingStaysShortOfFullUntilEveryRecordIsRemoved() async throws {
        let fixture = try makeToLocalFixture(count: 3)
        defer { cleanup(fixture) }
        var snapshots: [MigrationProgress] = []
        let subscription = fixture.manager.$progress.sink { snapshots.append($0) }
        defer { subscription.cancel() }

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        let live = snapshots.filter { $0.phase != nil }
        XCTAssertEqual(live.first?.fractionComplete, 0,
                       "the run opens on an empty ring, not the empty placeholder plan's 100%")
        let fractions = live.map(\.fractionComplete)
        XCTAssertEqual(fractions, fractions.sorted(), "the ring never moves backwards")

        let removing = live.filter { $0.phase == .removingRemoteCopy }
        XCTAssertFalse(removing.isEmpty)
        XCTAssertTrue(removing.filter { $0.removedCount < $0.removalTotal }.allSatisfy { $0.fractionComplete < 1 },
                      "the ring is not full while records are still being removed")
        XCTAssertEqual(removing.first?.fractionComplete ?? 0, 1 - MigrationPlan.sourceRemovalShare, accuracy: 0.0001)
        XCTAssertEqual(Set(removing.map(\.removalTotal)), [3])
        XCTAssertEqual(Set(removing.map(\.removedCount)), [0, 1, 2, 3],
                       "the removed count advances per record for \"Removing X of Y\"")
        XCTAssertEqual(removing.map(\.removingItemNumber).max(), 3, "the label never reads past \"3 of 3\"")
        XCTAssertEqual(snapshots.last?.fractionComplete ?? 0, 1, accuracy: 0.0001)
    }

    func testANewRunOnTheSameManagerDoesNotStartFromTheLastRunsProgress() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        // Leave the first run part-way: one item verified, then a pause.
        try await saveCheckpoint(fixture, states: [.verified, .pending])
        fixture.store.onFirstProgress = { [weak manager = fixture.manager] in
            Task { @MainActor in manager?.pause() }
        }
        fixture.store.fetchBlobProgressSteps = [0.5]
        await fixture.manager.start(plan: fixture.plan)
        XCTAssertGreaterThan(fixture.manager.progress.fractionComplete, 0)

        var snapshots: [MigrationProgress] = []
        let subscription = fixture.manager.$progress.dropFirst().sink { snapshots.append($0) }
        defer { subscription.cancel() }
        fixture.store.onFirstProgress = nil
        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(snapshots.first, .idle, "a new run clears the last run's snapshot before anything else")
    }

    func testAlbumMoveToLocalCancelInTheFirstPassLeavesEveryRecord() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        let plan = fixture.plan
        fixture.store.fetchBlobProgressSteps = [0.5]
        fixture.store.onFirstProgress = { [weak manager = fixture.manager] in
            Task { @MainActor in await manager?.cancel(plan: plan) }
        }

        await fixture.manager.start(plan: plan)

        XCTAssertEqual(fixture.manager.state, .idle)
        XCTAssertTrue(fixture.store.deleteCalls.isEmpty, "a cancel before the removal pass leaves the album whole in CloudKit")
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 0)
        let persisted = await MigrationPlanStore(album: fixture.album).load()
        XCTAssertNotNil(persisted?.cancelledAt, "the cancel is durable")
    }

    func testAlbumMoveToLocalIgnoresACancelOnceRecordsAreBeingRemoved() async throws {
        let fixture = try makeToLocalFixture(count: 3)
        defer { cleanup(fixture) }
        let plan = fixture.plan
        let cancelSent = Box(false)
        fixture.store.onDelete = { [weak manager = fixture.manager] _ in
            guard !cancelSent.value else { return }
            cancelSent.value = true
            Task { @MainActor in await manager?.cancel(plan: plan) }
        }

        await fixture.manager.start(plan: plan)

        XCTAssertTrue(cancelSent.value)
        XCTAssertEqual(fixture.manager.state, .completed,
                       "stopping part-way through the removal would leave the album half-deleted in CloudKit")
        XCTAssertEqual(fixture.store.deleteCalls.count, 3)
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 1)
    }

    func testAlbumMoveToLocalFetchesAnEvictedBlob() async throws {
        let fixture = try makeToLocalFixture(count: 1)
        defer { cleanup(fixture) }

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(fixture.store.fetchBlobCount, 1, "a blob missing from the cache is fetched from CloudKit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.localURL(fixture.ids[0]).path))
    }

    func testAlbumMoveToLocalFailedVerifyLeavesEveryRecordAndBlocksRemoval() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        // The first item's earlier download left an empty file, which cannot match
        // the cached ciphertext.
        try await saveCheckpoint(fixture, states: [.uploaded, .pending], localBytes: Data())

        await fixture.manager.start(plan: fixture.plan)

        guard case .failed = fixture.manager.state else {
            return XCTFail("expected a failed run, got \(fixture.manager.state)")
        }
        XCTAssertTrue(fixture.store.deleteCalls.isEmpty, "no record goes while any item is unverified")
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 0)
        let persisted = await MigrationPlanStore(album: fixture.album).load()
        XCTAssertEqual(persisted?.items.map(\.state), [.failed, .verified])
    }

    func testAlbumMoveToLocalResumedAfterAKillBetweenThePassesGoesStraightToRemoval() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        try await saveCheckpoint(fixture, states: [.verified, .verified])

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(fixture.store.fetchBlobCount, 0, "verified items are not downloaded again")
        XCTAssertEqual(fixture.store.deleteCalls.sorted(), fixture.recordNames.sorted())
        XCTAssertFalse(planFileExists(fixture))
    }

    func testAlbumMoveToLocalResumedAfterALocalCopyWentMissingDownloadsItAgainBeforeRemovingItsRecord() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        fixture.store.metadataToReturn = fixture.store.changeSet.changed
        try await saveCheckpoint(fixture, states: [.verified, .verified])
        try FileManager.default.removeItem(at: fixture.localURL(fixture.ids[0]))
        let sizesAtDelete = Box<[String: Int64]>([:])
        let recordNames = fixture.recordNames
        fixture.store.onDelete = { recordName in
            guard let index = recordNames.firstIndex(of: recordName) else { return }
            sizesAtDelete.value[recordName] = fixture.localURL(fixture.ids[index]).fileSizeBytes() ?? -1
        }

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(sizesAtDelete.value[recordNames[0]], 10,
                       "a record is only removed once its item has a full local copy again")
        for id in fixture.ids {
            XCTAssertEqual(fixture.localURL(id).fileSizeBytes(), 10, "every item came home")
        }
    }

    /// Puts `bytes` in the shared blob cache as the record's cached ciphertext, the
    /// way a download cut short or a damaged cache file would leave it.
    private func seedCacheEntry(_ bytes: Data, recordName: String, albumID: String) async throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("short-cache-\(UUID().uuidString)")
        try bytes.write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await CloudKitBlobCache.shared.store(recordName: recordName, changeTag: "tag",
                                                     albumID: albumID, from: staged)
        addTeardownBlock { await CloudKitBlobCache.shared.evict(recordName: recordName) }
    }

    func testAlbumMoveToLocalFromATruncatedCachedBlobRemovesNoRecordAndBringsAFullCopyHomeOnResume() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        let truncated = fixture.recordNames[0]
        try await seedCacheEntry(Data(repeating: 0xAA, count: 3), recordName: truncated,
                                 albumID: try XCTUnwrap(fixture.album.albumID))

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertFalse(fixture.store.callOrder.contains { if case .delete = $0 { return true }; return false },
                       "no record goes while a copy made from a truncated cache entry stands in for one")
        guard case .failed = fixture.manager.state else {
            return XCTFail("expected a failed run, got \(fixture.manager.state)")
        }
        let cached = await CloudKitBlobCache.shared.cachedURL(recordName: truncated, changeTag: "tag")
        XCTAssertNil(cached, "the truncated cache entry must be evicted so the next attempt downloads the record")
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 0)

        let sizesAtFirstDelete = Box<[Int64]?>(nil)
        fixture.store.onDelete = { _ in
            guard sizesAtFirstDelete.value == nil else { return }
            sizesAtFirstDelete.value = fixture.ids.map { fixture.localURL($0).fileSizeBytes() ?? -1 }
        }
        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(sizesAtFirstDelete.value, [10, 10], "records go only once every item has a full copy")
        XCTAssertEqual(fixture.store.deleteCalls.sorted(), fixture.recordNames.sorted())
    }

    func testAlbumMoveToLocalFromAShortChunkedAssemblyRemovesNoRecordAndBringsTheFullVideoHomeOnResume() async throws {
        let chunkStore = InMemoryChunkedBlobStore()
        let fixture = try makeToLocalFixture(count: 0, chunkStore: chunkStore)
        defer { cleanup(fixture) }
        let albumID = try XCTUnwrap(fixture.album.albumID)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plaintextURL = dir.appendingPathComponent("plain.bin")
        let enc3 = dir.appendingPathComponent("video.enc3")
        try Data((0..<5_000).map { UInt8($0 % 251) }).write(to: plaintextURL)
        let header = try SeekableEncryptedWriter(keyBytes: fixture.album.key.keyBytes, chunkSize: 1_000)
            .encrypt(source: plaintextURL, destination: enc3)
        let ciphertext = try Data(contentsOf: enc3)
        let id = UUID().uuidString
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .video)
        try await chunkStore.uploadChunks(enc3FileURL: enc3, mediaRecordName: recordName, progress: { _ in })
        // `sizeBytes` is the ENC2 original's, as a legacy video re-encrypted on its
        // way into CloudKit keeps; only the header gives the ciphertext's length.
        let record = CloudKitMediaMetadata(recordName: recordName, albumID: albumID, mediaID: id,
                                           mediaType: .video, createdAt: Date(),
                                           sizeBytes: Int64(ciphertext.count) - 700,
                                           creationDeviceID: "writer", schemaVersion: 1, keyFingerprint: "",
                                           recordChangeTag: "tag", chunkCount: header.chunkCount,
                                           plaintextLength: Int64(header.plaintextLength),
                                           encHeader: header.encoded())
        fixture.store.changeSet = CloudKitChangeSet(changed: [record], deleted: [], token: nil, moreComing: false)
        fixture.store.metadataToReturn = [record]
        // A chunked record carries no `encBlob` asset.
        fixture.store.fetchBlobError = CloudKitMediaStoreError.notFound
        // An assembly that stopped two chunks short of the header's geometry.
        try await seedCacheEntry(ciphertext.prefix(ciphertext.count - 2_100), recordName: recordName, albumID: albumID)
        let localURL = LocalStorageModel(album: fixture.local).driveURLForMedia(withID: id, type: .video)

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertFalse(fixture.store.callOrder.contains(.delete(recordName: recordName)),
                       "a copy of a short assembly must not be taken as proof the record can go")
        guard case .failed = fixture.manager.state else {
            return XCTFail("expected a failed run, got \(fixture.manager.state)")
        }
        let cached = await CloudKitBlobCache.shared.cachedURL(recordName: recordName, changeTag: "tag")
        XCTAssertNil(cached, "the short assembly must be evicted so the next attempt reassembles the chunks")

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed,
                       "a full reassembly verifies against the header, not the record's legacy sizeBytes")
        XCTAssertTrue(try Data(contentsOf: localURL) == ciphertext, "the full video comes home byte for byte")
        XCTAssertTrue(fixture.store.callOrder.contains(.delete(recordName: recordName)))
    }

    func testAlbumMoveToLocalFailedFinalizeKeepsThePlanForRetry() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        fixture.albumManager.finalizeToLocalError = AlbumError.albumNotFoundAtSourceLocation

        await fixture.manager.start(plan: fixture.plan)

        guard case .failed = fixture.manager.state else {
            return XCTFail("expected a failed run, got \(fixture.manager.state)")
        }
        XCTAssertTrue(planFileExists(fixture), "the checkpoint is kept so finalize is retried")
        let pending = await fixture.manager.pendingPlans()
        XCTAssertEqual(pending.map(\.id), [MigrationPlan.albumPlanID],
                       "a finalize-pending plan is surfaced for resume")

        fixture.albumManager.finalizeToLocalError = nil
        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(fixture.store.deleteCalls.count, 2, "the retry removes nothing twice")
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 2)
        XCTAssertFalse(planFileExists(fixture))
    }

    /// Every destructive step enumerates from the local index. If the reconcile
    /// that brings it current fails, the index may be stale or empty (a fresh
    /// device), so the move must stop before touching anything.
    func testAlbumMoveToLocalAbortsWhenReconcileFails() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        fixture.store.fetchChangesError = CloudKitMediaStoreError.underlying(NSError(domain: "test", code: 1))

        await fixture.manager.start(plan: fixture.plan)

        guard case .failed = fixture.manager.state else {
            return XCTFail("expected a failed run, got \(fixture.manager.state)")
        }
        XCTAssertGreaterThan(fixture.store.fetchChangesCount, 0,
                             "the abort must come from an attempted reconcile, not an earlier guard")
        XCTAssertTrue(fixture.store.deleteCalls.isEmpty, "no media record may be touched after a failed reconcile")
        XCTAssertTrue(fixture.store.deletedAlbumCalls.isEmpty, "the album record must not be deleted")
        XCTAssertEqual(fixture.store.fetchBlobCount, 0)
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 0)
    }

    /// The full round trip against ONE shared in-memory store: the engine lands a
    /// real album in "CloudKit", then drains it back. The phase order and count
    /// monotonicity are what the blocking overlay renders, so they are the contract.
    func testAlbumMoveToLocalReportsPhasesAndMonotonicCounts() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]
        let engine = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in shared })
        defer { cleanup(album) }

        let ids = try await seedLocalAlbum(count: 3, albumManager: albumManager, album: album)
        await engine.start(album: album)
        XCTAssertEqual(engine.state, .completed, "precondition: the forward migration must land the album in CloudKit")
        let cloudAlbum = try XCTUnwrap(engine.destinationAlbum)
        defer {
            try? FileManager.default.removeItem(at: CloudKitStorageModel(album: cloudAlbum).baseURL)
            try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: cloudAlbum))
        }
        albumManager.albumsOnDisk = [cloudAlbum]

        var snapshots: [MigrationProgress] = []
        let subscription = engine.$progress.dropFirst().sink { snapshots.append($0) }
        defer { subscription.cancel() }
        await engine.start(plan: try MigrationPlan.album(cloudAlbum, items: []))

        XCTAssertEqual(engine.state, .completed)
        XCTAssertEqual(albumManager.finalizeToLocalCallCount, 1)
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: id).path),
                          "every item is back in the local layout")
        }
        let phases = snapshots.compactMap(\.phase)
        XCTAssertEqual(phases.first, .preparing, "the move announces itself before the reconcile")
        XCTAssertEqual(phases.last, .removingRemoteCopy, "the last phase is the cloud-plane teardown")
        XCTAssertNil(snapshots.last?.phase, "the terminal snapshot carries no phase")
        let removalStart = try XCTUnwrap(phases.firstIndex(of: .removingRemoteCopy))
        XCTAssertFalse(phases[removalStart...].contains(.downloading), "no download happens once removal starts")
        let downloading = snapshots.filter { $0.phase == .downloading }
        XCTAssertFalse(downloading.isEmpty)
        XCTAssertTrue(downloading.allSatisfy { $0.totalCount == 3 },
                      "the total holds steady across the run; got \(downloading.map(\.totalCount))")
        let counts = snapshots.map(\.verifiedCount)
        XCTAssertEqual(counts, counts.sorted(), "verified counts never go backwards; got \(counts)")
    }
}

// MARK: - Destination album identity and transport

extension CloudKitMigrationManagerTests {

    /// A real `AlbumManager` over an isolated synced store, so finalize, enumeration
    /// and the hidden/cover settings are the production ones. The engine and the
    /// manager's own record pushes share `store`.
    private struct TransportHarness {
        let engine: CloudKitMigrationManager
        let albumManager: AlbumManager
        let syncedStore: AlbumsSyncedStore
        let key: PrivateKey
    }

    private func makeTransportHarness(store: CloudKitMediaStoring,
                                      key: PrivateKey? = nil,
                                      function: String = #function) -> TransportHarness {
        let key = key ?? PrivateKey(name: "key", keyBytes: randomKey(), creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let dataStore = SyncedDataStore(keyManager: keyManager,
                                        defaults: makeIsolatedDefaults(function),
                                        cloudStore: MockKeyValueStore())
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        let priorToggle = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        addTeardownBlock {
            CloudKitStoreProvider.makeStore = priorMakeStore
            FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: priorToggle)
        }
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: dataStore)
        return TransportHarness(engine: CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store }),
                                albumManager: albumManager,
                                syncedStore: AlbumsSyncedStore(store: dataStore),
                                key: key)
    }

    /// Removes everything a CloudKit album leaves on this device.
    private func cleanupCloudKitAlbum(albumID: String, key: PrivateKey, name: String) {
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key, albumID: albumID)
        try? CloudKitAlbumMarker.remove(albumID: albumID)
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: album))
        try? FileManager.default.removeItem(at: AlbumSizeSidecar.sidecarURL(for: album))
        try? FileManager.default.removeItem(at: AlbumCoverSidecar.sidecarURL(for: album))
    }

    private func record(for name: String, key: PrivateKey, albumID: String = UUID().uuidString,
                        createdAt: Date = Date()) -> CloudKitAlbumMetadata {
        CloudKitAlbumMetadata(albumID: albumID,
                              encName: Album(name: name, storageOption: .cloudKit, creationDate: createdAt,
                                             key: key).encryptedPathComponent,
                              createdAt: createdAt,
                              isHidden: false,
                              schemaVersion: CloudKitSchema.currentSchemaVersion,
                              keyFingerprint: key.keychainLabel,
                              recordChangeTag: "tag")
    }

    func testTheDestinationAlbumIDIsResolvedOnceAndPersistedInThePlan() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }
        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)

        let first = try await manager.plan(album: album)

        let albumID = try XCTUnwrap(first.destination.cloudKitAlbumID)
        XCTAssertNotNil(UUID(uuidString: albumID), "a new CloudKit album gets a minted UUID")
        XCTAssertEqual(first.destination.albumID, "\(albumID)_cloudKit",
                       "the endpoint names the destination album's id, which the plan paths and active set key on")
        let persisted = await MigrationPlanStore(album: album).load()
        XCTAssertEqual(persisted?.destination.cloudKitAlbumID, albumID, "the id is persisted with the plan")

        let second = try await manager.plan(album: album)
        XCTAssertEqual(second.destination.cloudKitAlbumID, albumID, "a re-plan reuses the persisted id")
        XCTAssertEqual(store.fetchAllAlbumsCount, 1, "the server is asked once; a re-plan never resolves again")
    }

    func testACrashAfterTheAlbumRecordSaveResumesIntoTheSameAlbum() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }
        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        // The run stops after the album record is saved and before any media lands.
        store.uploadErrorOnce = CloudKitMediaStoreError.quotaExceeded

        await manager.start(album: album)
        XCTAssertEqual(manager.state, .failed(.quota), "precondition: the first run halted")
        XCTAssertEqual(store.savedAlbumCalls.count, 1, "precondition: the album record was saved")
        let landed = try await store.fetchMetadata(albumID: "", includeThumbnail: false)
        XCTAssertTrue(landed.isEmpty, "precondition: no media landed before the halt")

        let resumed = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store })
        await resumed.start(album: album)

        XCTAssertEqual(resumed.state, .completed)
        XCTAssertEqual(store.fetchAllAlbumsCount, 1, "the resume reads the id from the plan instead of resolving again")
        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.count, 1, "the resume lands in the album the first run created, not a second one")
        let albumID = try XCTUnwrap(albums.first?.albumID)
        XCTAssertEqual(Set(store.savedAlbumCalls.map(\.albumID)), [albumID])
        XCTAssertEqual(Set(store.uploadedItems.map(\.albumID)), [albumID])
        XCTAssertEqual(albumManager.finalizedAlbums.map(\.albumID), [albumID])
    }

    func testAMoveToCloudKitAdoptsTheServerAlbumWithTheSameNameAndKey() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }
        _ = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let otherKey = PrivateKey(name: "other", keyBytes: randomKey(), creationDate: Date())
        store.seedAlbum(record(for: album.name, key: otherKey))
        store.seedAlbum(record(for: "someone else", key: album.key))
        let existing = record(for: album.name, key: album.key)
        store.seedAlbum(existing)

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(manager.destinationAlbum?.albumID, existing.albumID)
        XCTAssertEqual(Set(store.uploadedItems.map(\.albumID)), [existing.albumID],
                       "the media lands in the album another device already moved")
        XCTAssertEqual(albumManager.finalizedAlbums.map(\.albumID), [existing.albumID])
        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.count, 3, "no album is minted beside the adopted one")
    }

    func testAMoveToCloudKitDoesNotAdoptAnAlbumQueuedForDeletion() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        defer { cleanup(album) }
        _ = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)
        let doomed = record(for: album.name, key: album.key)
        store.seedAlbum(doomed)
        CloudKitAlbumDeleteQueue().enqueue(doomed.albumID)
        defer { CloudKitAlbumDeleteQueue().remove(doomed.albumID) }

        let plan = try await manager.plan(album: album)

        let albumID = try XCTUnwrap(plan.destination.cloudKitAlbumID)
        XCTAssertNotEqual(albumID, doomed.albumID, "its pending delete would cascade to the media moved into it")
    }

    func testAMediaRecordOwnedByAnotherAlbumIsSkippedNotReparented() async throws {
        let album = makeAlbum()
        let (manager, albumManager, store) = makeExecutableManager(for: album)
        store.reflectUploadsInMetadata = true
        defer { cleanup(album) }
        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: album)
        let plan = try await manager.plan(album: album)
        let foreign = try XCTUnwrap(plan.items.first { $0.mediaID == ids[0] })
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: foreign.recordName, albumID: "another-album", mediaID: foreign.mediaID,
            mediaType: foreign.mediaType, createdAt: foreign.createdAt, sizeBytes: foreign.sizeBytes,
            creationDeviceID: "other-device", schemaVersion: CloudKitSchema.currentSchemaVersion,
            recordChangeTag: "tag")]

        await manager.start(album: album)

        XCTAssertEqual(manager.state, .completed, "a skipped item does not hold the move short of finishing")
        XCTAssertEqual(store.uploadCalls, [ids[1]], "the foreign-owned record is never saved over")
        let owner = try await store.confirmAlbum(recordName: foreign.recordName)
        XCTAssertEqual(owner, "another-album", "the record stays with its album")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: ids[0]).path),
                      "the skipped item's local original stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: album, id: ids[1]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: albumManager.storageModel(for: album)!.baseURL.path),
                      "a directory still holding a file is not removed as drained")
        XCTAssertEqual(albumManager.finalizeCallCount, 1)
    }

    func testAMoveToLocalCreatesTheEncNameDirectoryDeletesTheAlbumRecordAndRemovesTheMarker() async throws {
        let store = MockCloudKitMediaStore()
        let harness = makeTransportHarness(store: store)
        let albumID = UUID().uuidString
        let cloudAlbum = Album(name: "back-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                               key: harness.key, albumID: albumID)
        let encName = cloudAlbum.encryptedPathComponent
        let localURL = LocalStorageModel.albumsURL.appendingPathComponent(encName, isDirectory: true)
        defer {
            cleanupCloudKitAlbum(albumID: albumID, key: harness.key, name: cloudAlbum.name)
            try? FileManager.default.removeItem(at: localURL)
        }
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: false).write(albumID: albumID)
        try await AlbumSizeSidecar(album: cloudAlbum).apply(updates: ["stale#0": 1])
        try await AlbumCoverSidecar(album: cloudAlbum).setCoverMediaID("cover")
        let id = UUID().uuidString
        store.changeSet = CloudKitChangeSet(
            changed: [CloudKitMediaMetadata(recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                                            albumID: albumID, mediaID: id, mediaType: .photo, createdAt: Date(),
                                            sizeBytes: 10, creationDeviceID: "mock", schemaVersion: 1,
                                            recordChangeTag: "tag")],
            deleted: [], token: nil, moreComing: false)
        store.metadataToReturn = store.changeSet.changed
        store.blobContents = Data(repeating: 0xAB, count: 10)

        await harness.engine.start(plan: try MigrationPlan.album(cloudAlbum, items: []))

        XCTAssertEqual(harness.engine.state, .completed)
        let itemURL = LocalStorageModel(album: Album.localTwin(of: cloudAlbum)).driveURLForMedia(withID: id, type: .photo)
        XCTAssertEqual(itemURL.deletingLastPathComponent().lastPathComponent, encName,
                       "the local directory is named by the album's encName, byte for byte")
        XCTAssertEqual(try Data(contentsOf: itemURL), store.blobContents, "the item lands in it")
        XCTAssertEqual(store.deletedAlbumCalls, [albumID], "the album record is deleted under its id")
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID), "album.json is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudKitAlbumMarker.directoryURL(albumID: albumID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AlbumSizeSidecar.sidecarURL(for: cloudAlbum).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AlbumCoverSidecar.sidecarURL(for: cloudAlbum).path))
        let albums = harness.albumManager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertFalse(albums.contains { $0.albumID == albumID })
        let local = try XCTUnwrap(albums.first { $0.name == cloudAlbum.name })
        XCTAssertEqual(local.storageOption, .local)
        XCTAssertNil(local.albumID)
    }

    func testAMoveToLocalWithANameClashFailsBeforeAnyTransfer() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer { cleanup(fixture) }
        // A hidden local album with the same name: the check counts hidden albums too.
        let clash = Album(name: fixture.album.name, storageOption: .local, creationDate: Date(), key: fixture.album.key)
        fixture.albumManager.hiddenAlbumsOnDisk = [clash]

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .failed(.other(L10n.albumExistsError)))
        XCTAssertEqual(fixture.store.fetchChangesCount, 0, "nothing is reconciled")
        XCTAssertEqual(fixture.store.fetchBlobCount, 0, "nothing is downloaded")
        XCTAssertTrue(fixture.store.deleteCalls.isEmpty)
        XCTAssertTrue(fixture.store.deletedAlbumCalls.isEmpty)
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStorageModel(album: fixture.local).baseURL.path),
                       "no local directory is created")
    }

    func testARoundTripBackToCloudKitResolvesAFreshIDAndLeavesNoOrphanRecord() async throws {
        let store = InMemoryCloudKitMediaStore()
        let harness = makeTransportHarness(store: store)
        let album = Album(name: "trip-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: harness.key)
        defer { cleanup(album) }
        _ = try await seedLocalAlbum(count: 2, albumManager: harness.albumManager, album: album)

        await harness.engine.start(album: album)
        XCTAssertEqual(harness.engine.state, .completed, "precondition: the first move to CloudKit")
        let firstID = try XCTUnwrap(harness.engine.destinationAlbum?.albumID)
        defer { cleanupCloudKitAlbum(albumID: firstID, key: harness.key, name: album.name) }
        let cloudAlbum = try XCTUnwrap(harness.albumManager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.albumID == firstID })

        let back = CloudKitMigrationManager(albumManager: harness.albumManager, storeFactory: { _ in store })
        await back.start(plan: try MigrationPlan.album(cloudAlbum, items: []))
        XCTAssertEqual(back.state, .completed, "precondition: the move back to this device")
        let local = try XCTUnwrap(harness.albumManager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.name == album.name })
        XCTAssertEqual(local.storageOption, .local)

        let again = CloudKitMigrationManager(albumManager: harness.albumManager, storeFactory: { _ in store })
        await again.start(album: local)
        XCTAssertEqual(again.state, .completed)
        let secondID = try XCTUnwrap(again.destinationAlbum?.albumID)
        defer { cleanupCloudKitAlbum(albumID: secondID, key: harness.key, name: album.name) }

        XCTAssertNotEqual(secondID, firstID, "the first id went with the move back")
        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.map(\.albumID), [secondID], "no record of the first album is left behind")
        XCTAssertEqual(store.liveRecordNames.count, 2)
        let firstMembers = try await store.fetchMetadata(albumID: firstID, includeThumbnail: false)
        let secondMembers = try await store.fetchMetadata(albumID: secondID, includeThumbnail: false)
        XCTAssertTrue(firstMembers.isEmpty)
        XCTAssertEqual(secondMembers.count, 2)
    }

    func testAHiddenLocalAlbumMovedToCloudKitKeepsItsFlagAndCoverAndLeavesNoNameKeyedEntry() async throws {
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let harness = makeTransportHarness(store: store)
        let album = Album(name: "hidden-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: harness.key)
        defer { cleanup(album) }
        let ids = try await seedLocalAlbum(count: 1, albumManager: harness.albumManager, album: album)
        harness.albumManager.setIsAlbumHidden(true, album: album)
        harness.albumManager.setAlbumCoverImage(album: album,
                                                image: InteractableMedia<EncryptedMedia>(emptyWithType: .stillPhoto, id: ids[0]))
        XCTAssertEqual(try harness.syncedStore.fetchAlbum(name: album.name)?.isHidden, true, "precondition")

        await harness.engine.start(album: album)

        XCTAssertEqual(harness.engine.state, .completed)
        let cloudAlbum = try XCTUnwrap(harness.engine.destinationAlbum)
        let albumID = try XCTUnwrap(cloudAlbum.albumID)
        defer { cleanupCloudKitAlbum(albumID: albumID, key: harness.key, name: album.name) }
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertTrue(marker.isHidden)
        XCTAssertEqual(marker.coverMediaID, ids[0])
        XCTAssertTrue(harness.albumManager.isAlbumHidden(cloudAlbum))
        XCTAssertEqual(harness.albumManager.getAlbumCoverImageId(album: cloudAlbum), ids[0])
        let recordSave = try XCTUnwrap(store.savedAlbumCalls.first)
        XCTAssertTrue(recordSave.isHidden, "the record carries the hidden flag from the start")
        XCTAssertEqual(recordSave.coverMediaID, ids[0], "and the cover")
        XCTAssertNil(try harness.syncedStore.fetchAlbum(name: album.name),
                     "the local album's AlbumsSyncedStore entry is removed")
    }

    func testAMoveBackToLocalRestoresTheHiddenFlagAndCoverIntoTheSyncedStore() async throws {
        let store = MockCloudKitMediaStore()
        let harness = makeTransportHarness(store: store)
        let albumID = UUID().uuidString
        let cloudAlbum = Album(name: "restore-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                               key: harness.key, albumID: albumID)
        let localURL = LocalStorageModel.albumsURL.appendingPathComponent(cloudAlbum.encryptedPathComponent,
                                                                          isDirectory: true)
        defer {
            cleanupCloudKitAlbum(albumID: albumID, key: harness.key, name: cloudAlbum.name)
            try? FileManager.default.removeItem(at: localURL)
            harness.syncedStore.deleteAlbum(name: cloudAlbum.name)
        }
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: true,
                                coverMediaID: CloudKitAlbumMarker.disabledCoverID).write(albumID: albumID)
        XCTAssertNil(try harness.syncedStore.fetchAlbum(name: cloudAlbum.name), "precondition")

        await harness.engine.start(plan: try MigrationPlan.album(cloudAlbum, items: []))

        XCTAssertEqual(harness.engine.state, .completed)
        let entry = try XCTUnwrap(try harness.syncedStore.fetchAlbum(name: cloudAlbum.name))
        XCTAssertTrue(entry.isHidden)
        XCTAssertEqual(entry.coverImageId, CloudKitAlbumMarker.disabledCoverID)
        let local = Album.localTwin(of: cloudAlbum)
        XCTAssertTrue(harness.albumManager.isAlbumHidden(local))
        XCTAssertTrue(harness.albumManager.isAlbumCoverImageDisabled(album: local))
    }
}

/// A reference cell for state a `@Sendable` mock-store hook writes and the test reads.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Chunked uploads that resume across attempts

/// These run the real `CloudKitMediaStore` and `CloudKitChunkedBlobStore` over
/// `FakeAssetDatabase`, which keeps chunk bytes, because the property under test is
/// whether the ciphertext the server ends up holding decrypts. A store double that
/// only records calls cannot say that.
extension CloudKitMigrationManagerTests {

    private struct ChunkedServer {
        let database = FakeAssetDatabase()
        let defaults = makeIsolatedDefaults("chunked-server")

        func container() -> CloudKitContainer {
            CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: .available),
                              zoneProvisioner: StubZoneProvisioner(),
                              defaults: defaults)
        }

        func chunkStore() -> CloudKitChunkedBlobStore {
            CloudKitChunkedBlobStore(container: container(),
                                     adapter: database,
                                     zoneProvisioner: StubZoneProvisioner(),
                                     defaults: defaults)
        }

        func mediaStore() -> CloudKitMediaStore {
            CloudKitMediaStore(container: container(), adapter: database, defaults: defaults,
                               chunkStore: chunkStore())
        }

        func chunkRecordNames(of mediaRecordName: String) -> [String] {
            database.allRecords
                .filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType
                    && ($0[ChunkedBlobSchema.Chunk.mediaRecordName] as? String) == mediaRecordName }
                .map(\.recordID.recordName)
        }

        func savedChunkNames() -> [String] {
            database.savedRecordBatches.flatMap { $0 }
                .filter { $0.recordType == ChunkedBlobSchema.Chunk.recordType }
                .map(\.recordID.recordName)
                .sorted()
        }

        /// Reads the record back the way a second device would: a fresh coordinator,
        /// an empty cache, and nothing learned from the upload.
        func readBack(recordName: String, albumID: String, key: [UInt8], into dir: URL) async throws -> Data {
            let coordinator = CloudKitSyncCoordinator(
                albumID: albumID,
                store: mediaStore(),
                cache: CloudKitBlobCache(baseDir: dir.appendingPathComponent("cache-\(UUID().uuidString)"),
                                         maxBytes: 512 * 1024 * 1024),
                indexStore: MediaIndexStore(keyBytes: key,
                                            indexURL: dir.appendingPathComponent("index-\(UUID().uuidString).encindex")),
                bus: FileOperationBus(),
                uploadQueue: CloudKitUploadQueue(baseDir: dir.appendingPathComponent("queue-\(UUID().uuidString)")),
                deleteQueue: CloudKitMediaDeleteQueue(suiteName: makeIsolatedSuiteName("chunked-readback")),
                chunkStore: chunkStore()
            )
            let local = try await coordinator.ensureBlobLocal(recordName: recordName, albumID: albumID) { _ in }
            let encrypted = EncryptedMedia(source: .url(local), mediaType: .video, id: "readback")
            let handler = SecretFileHandler(keyBytes: key, source: encrypted,
                                            targetURL: dir.appendingPathComponent("readback-\(UUID().uuidString).mov"))
            let cleartext = try await handler.decryptToURL()
            return try Data(contentsOf: try XCTUnwrap(cleartext.url))
        }
    }

    private func makeChunkedManager(for album: Album, server: ChunkedServer) -> (CloudKitMigrationManager, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let store = server.mediaStore()
        return (CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store }), albumManager)
    }

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func randomPlaintext(bytes: Int) -> Data {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        return data
    }

    /// Writes a legacy ENC2 video large enough that the migration re-encrypts it
    /// into ENC3 chunks. Returns its media id and plaintext.
    private func seedLegacyChunkSizedVideo(in album: Album, scratch: URL) async throws -> (id: String, plaintext: Data) {
        let model = album.storageOption.modelForType.init(album: album)
        try model.initializeDirectories()
        let id = UUID().uuidString
        let plaintext = randomPlaintext(bytes: SeekableEncryptedFormat.threshold + 1024 * 1024)
        let plaintextURL = scratch.appendingPathComponent("\(id).mov")
        try plaintext.write(to: plaintextURL)
        let destination = model.driveURLForMedia(withID: id, type: .video)
        let handler = SecretFileHandlerV2(keyBytes: album.key.keyBytes,
                                          source: CleartextMedia(source: plaintextURL, mediaType: .video, id: id),
                                          targetURL: destination)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        try FileManager.default.removeItem(at: plaintextURL)
        XCTAssertFalse(SeekableEncryptedHeader.isSeekableFormat(fileURL: destination), "precondition: the source is legacy, not ENC3")
        return (id, plaintext)
    }

    private func withCloudKitStorageEnabled(_ body: () async throws -> Void) async rethrows {
        let original = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: original) }
        try await body()
    }

    /// The first attempt re-encrypts and gets part of its chunks onto the server,
    /// then the commit fails. The resume re-encrypts under a new file id; if it
    /// keeps the first attempt's chunks and commits its own header, the video on
    /// the server no longer decrypts, and the local original is gone.
    func testAResumedLegacyVideoMigrationStoresAVideoThatDecrypts() async throws {
        try await withCloudKitStorageEnabled {
            let album = makeAlbum()
            let server = ChunkedServer()
            let (manager, _) = makeChunkedManager(for: album, server: server)
            let scratch = try scratchDirectory()
            defer { cleanup(album); try? FileManager.default.removeItem(at: scratch) }

            let video = try await seedLegacyChunkSizedVideo(in: album, scratch: scratch)
            let recordName = MediaRecordName.componentRecordName(mediaID: video.id, type: .video)

            server.database.failNextSave(ofRecordType: CloudKitSchema.EncMedia.recordType,
                                         with: CKErrorFactory.error(.quotaExceeded))
            await manager.start(album: album)
            XCTAssertEqual(manager.state, .failed(.quota), "precondition: the first attempt stopped before its commit")
            let haltedAlbumID = await MigrationPlanStore(album: album).load()?.destination.cloudKitAlbumID
            let firstAttemptChunks = server.chunkRecordNames(of: recordName).sorted()
            XCTAssertGreaterThan(firstAttemptChunks.count, 4, "precondition: the first attempt wrote chunks")
            // Interrupted mid-chunks: only the first few of them reached the server.
            for name in firstAttemptChunks where !["#c0", "#c1", "#c2"].contains(where: name.hasSuffix) {
                server.database.removeRecord(named: name)
            }

            await manager.resume(album: album)

            XCTAssertEqual(manager.state, .completed)
            let loaded = await MigrationPlanStore(album: album).load()
            XCTAssertNil(loaded, "the move finished")
            let albumID = try XCTUnwrap(haltedAlbumID)
            do {
                let readBack = try await server.readBack(recordName: recordName, albumID: albumID,
                                                         key: album.key.keyBytes, into: scratch)
                XCTAssertTrue(readBack == video.plaintext,
                              "the video on the server must decrypt to the original, since the local original is gone")
            } catch {
                XCTFail("the video on the server does not decrypt, and the local original is gone: \(error)")
            }
        }
    }

    /// A record committed by an earlier attempt whose checkpoint never learned of
    /// it (the save landed, the reply did not) holds a header that matches its own
    /// chunks. Re-encrypting and rewriting those chunks under a new file id would
    /// corrupt it, so the rewrite must be refused and the existing record verified.
    func testALegacyVideoAlreadyCommittedByALostAttemptIsNotOverwritten() async throws {
        try await withCloudKitStorageEnabled {
            let album = makeAlbum()
            let server = ChunkedServer()
            server.database.rejectsFreshSaveOverExisting = [CloudKitSchema.EncMedia.recordType]
            let (manager, _) = makeChunkedManager(for: album, server: server)
            let scratch = try scratchDirectory()
            defer { cleanup(album); try? FileManager.default.removeItem(at: scratch) }

            let video = try await seedLegacyChunkSizedVideo(in: album, scratch: scratch)
            let recordName = MediaRecordName.componentRecordName(mediaID: video.id, type: .video)

            server.database.failNextSave(ofRecordType: CloudKitSchema.EncMedia.recordType,
                                         with: CKErrorFactory.error(.quotaExceeded),
                                         afterPersisting: true)
            await manager.start(album: album)
            XCTAssertEqual(manager.state, .failed(.quota), "precondition: the device never heard the commit landed")
            let haltedAlbumID = await MigrationPlanStore(album: album).load()?.destination.cloudKitAlbumID
            XCTAssertTrue(server.database.hasRecord(named: recordName), "precondition: the commit did land")
            server.database.resetObservations()

            await manager.resume(album: album)

            XCTAssertEqual(manager.state, .completed)
            XCTAssertEqual(server.savedChunkNames(), [], "a committed record's chunks are never rewritten")
            let albumID = try XCTUnwrap(haltedAlbumID)
            do {
                let readBack = try await server.readBack(recordName: recordName, albumID: albumID,
                                                         key: album.key.keyBytes, into: scratch)
                XCTAssertTrue(readBack == video.plaintext, "the committed video still decrypts")
            } catch {
                XCTFail("the committed video no longer decrypts: \(error)")
            }
        }
    }

    /// An ENC3 source is uploaded byte for byte on every attempt, so a resume keeps
    /// every chunk already on the server and sends only the missing ones.
    func testAResumedENC3MigrationUploadsOnlyTheMissingChunks() async throws {
        try await withCloudKitStorageEnabled {
            let album = makeAlbum()
            let server = ChunkedServer()
            let (manager, _) = makeChunkedManager(for: album, server: server)
            let scratch = try scratchDirectory()
            defer { cleanup(album); try? FileManager.default.removeItem(at: scratch) }

            let model = album.storageOption.modelForType.init(album: album)
            try model.initializeDirectories()
            let id = UUID().uuidString
            let plaintext = randomPlaintext(bytes: 10_000)
            let plaintextURL = scratch.appendingPathComponent("\(id).mov")
            try plaintext.write(to: plaintextURL)
            _ = try SeekableEncryptedWriter(keyBytes: album.key.keyBytes, chunkSize: 1_000)
                .encrypt(source: plaintextURL, destination: model.driveURLForMedia(withID: id, type: .video), metadata: nil)
            let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .video)

            server.database.failNextSave(ofRecordType: CloudKitSchema.EncMedia.recordType,
                                         with: CKErrorFactory.error(.quotaExceeded))
            await manager.start(album: album)
            XCTAssertEqual(manager.state, .failed(.quota), "precondition: the first attempt stopped before its commit")
            let haltedAlbumID = await MigrationPlanStore(album: album).load()?.destination.cloudKitAlbumID
            XCTAssertEqual(server.chunkRecordNames(of: recordName).count, 10)
            server.database.removeRecord(named: "\(recordName)#c4")
            server.database.removeRecord(named: "\(recordName)#c9")
            server.database.resetObservations()

            await manager.resume(album: album)

            XCTAssertEqual(manager.state, .completed)
            XCTAssertEqual(server.savedChunkNames(), ["\(recordName)#c4", "\(recordName)#c9"],
                           "an ENC3 resume keeps the chunks already on the server")
            let albumID = try XCTUnwrap(haltedAlbumID)
            let readBack = try await server.readBack(recordName: recordName, albumID: albumID,
                                                     key: album.key.keyBytes, into: scratch)
            XCTAssertTrue(readBack == plaintext)
        }
    }

    /// A move of selected items, starting clean, carries an ENC3 video across as
    /// the chunks of its existing ciphertext: every chunk and the record land in
    /// the destination album, the video on the server decrypts, and only then is
    /// the local file gone.
    func testAForwardItemMoveOfAChunkedVideoFromACleanStartStoresAVideoThatDecrypts() async throws {
        try await withCloudKitStorageEnabled {
            let source = makeAlbum()
            let destination = Album(name: "mig-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                                    key: source.key, albumID: UUID().uuidString)
            let server = ChunkedServer()
            let (manager, albumManager) = makeChunkedManager(for: source, server: server)
            albumManager.albumsOnDisk = [source, destination]
            let scratch = try scratchDirectory()
            defer {
                cleanup(source)
                cleanup(destination)
                try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: source))
                try? FileManager.default.removeItem(at: scratch)
            }

            let model = source.storageOption.modelForType.init(album: source)
            try model.initializeDirectories()
            let id = UUID().uuidString
            let plaintext = randomPlaintext(bytes: 10_000)
            let plaintextURL = scratch.appendingPathComponent("\(id).mov")
            try plaintext.write(to: plaintextURL)
            let sourceURL = model.driveURLForMedia(withID: id, type: .video)
            _ = try SeekableEncryptedWriter(keyBytes: source.key.keyBytes, chunkSize: 1_000)
                .encrypt(source: plaintextURL, destination: sourceURL, metadata: nil)
            let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .video)
            let plan = try MigrationPlan.items(source: source, destination: destination, items: [
                MigrationItem(mediaID: id, recordName: recordName, mediaType: .video, createdAt: Date(),
                              sizeBytes: try XCTUnwrap(sourceURL.fileSizeBytes()))
            ])

            let started = await manager.start(plan: plan)

            XCTAssertTrue(started)
            XCTAssertEqual(manager.state, .completed)
            XCTAssertEqual(server.savedChunkNames(), (0..<10).map { "\(recordName)#c\($0)" }.sorted(),
                           "every chunk of the existing ciphertext is uploaded once")
            let record = try XCTUnwrap(server.database.allRecords.first { $0.recordID.recordName == recordName })
            XCTAssertEqual(record[CloudKitSchema.EncMedia.albumID] as? String, destination.albumID,
                           "the record lands in the destination album")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path),
                           "the local file is removed once the record verifies")
            let destinationEntries = await MediaIndexStore(album: destination).current()?.entries ?? []
            XCTAssertTrue(destinationEntries.contains { $0.id == id && $0.hasVideoComponent },
                          "the destination album lists the video")
            let readBack = try await server.readBack(recordName: recordName, albumID: try XCTUnwrap(destination.albumID),
                                                     key: source.key.keyBytes, into: scratch)
            XCTAssertTrue(readBack == plaintext, "the video on the server decrypts to the original")
        }
    }
}

// MARK: - Members a move back to this device did not plan

extension CloudKitMigrationManagerTests {

    /// A record another device adds to the album while its records are being removed
    /// is brought home and removed too, and only then does the album record go.
    func testAlbumMoveToLocalMovesARecordAddedToTheServerAfterPlanning() async throws {
        let store = MockCloudKitMediaStore()
        let harness = makeTransportHarness(store: store)
        let albumID = UUID().uuidString
        let cloudAlbum = Album(name: "late-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                               key: harness.key, albumID: albumID)
        let localModel = LocalStorageModel(album: Album.localTwin(of: cloudAlbum))
        defer {
            CloudKitMigrationManager.boundaryHook = nil
            cleanupCloudKitAlbum(albumID: albumID, key: harness.key, name: cloudAlbum.name)
            try? FileManager.default.removeItem(at: localModel.baseURL)
        }
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: false).write(albumID: albumID)
        store.addServerRecord(albumID: albumID)
        store.addServerRecord(albumID: albumID)
        store.blobContents = Data(repeating: 0xAB, count: 10)
        let lateID = UUID().uuidString
        let late = Box<String?>(nil)
        CloudKitMigrationManager.boundaryHook = { boundary in
            guard late.value == nil, case .removing(removed: 1) = boundary else { return }
            late.value = store.addServerRecord(albumID: albumID, mediaID: lateID)
        }

        await harness.engine.start(plan: try MigrationPlan.album(cloudAlbum, items: []))

        XCTAssertEqual(harness.engine.state, .completed)
        let lateRecord = try XCTUnwrap(late.value, "precondition: the record arrived during the removal pass")
        XCTAssertEqual(try Data(contentsOf: localModel.driveURLForMedia(withID: lateID, type: .photo)), store.blobContents,
                       "the late record is downloaded into the local album")
        XCTAssertTrue(store.deleteCalls.contains(lateRecord), "and its record is removed like the planned ones")
        XCTAssertEqual(store.deletedAlbumCalls, [albumID])
        let order = store.callOrder
        let lateDelete = try XCTUnwrap(order.firstIndex(of: .delete(recordName: lateRecord)))
        let albumDelete = try XCTUnwrap(order.firstIndex(of: .deleteAlbum(albumID: albumID)))
        XCTAssertLessThan(lateDelete, albumDelete,
                          "the album record goes only after the late record's local copy is safe")
    }

    /// An album that gains a member on every pass ends the run as a retryable
    /// failure before its record is deleted, with the newest member checkpointed.
    func testAlbumMoveToLocalKeepsTheAlbumRecordWhileUnplannedMembersKeepArriving() async throws {
        let fixture = try makeToLocalFixture(count: 1)
        defer {
            CloudKitMigrationManager.boundaryHook = nil
            cleanup(fixture)
        }
        let albumID = try XCTUnwrap(fixture.album.albumID)
        let store = fixture.store
        let arrivals = Box<[String]>([])
        CloudKitMigrationManager.boundaryHook = { boundary in
            guard case .removing(removed: 0) = boundary else { return }
            arrivals.value.append(store.addServerRecord(albumID: albumID))
        }

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .failed(.other(L10n.CloudKitMigration.albumKeptGainingItems)))
        XCTAssertEqual(arrivals.value.count, CloudKitMigrationManager.maxMoveBackPasses,
                       "every pass found a new member")
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 0, "the album record is never deleted")
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty)
        let newest = try XCTUnwrap(arrivals.value.last)
        XCTAssertFalse(store.deleteCalls.contains(newest), "the newest member's record is left alone")
        for recordName in arrivals.value.dropLast() {
            let mediaID = MediaRecordName.mediaID(from: recordName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.localURL(mediaID).path),
                          "a member brought home earlier is in the local album before its record goes")
        }
        let loaded = await MigrationPlanStore(album: fixture.album).load()
        let persisted = try XCTUnwrap(loaded, "the checkpoint is kept for a resume")
        XCTAssertEqual(persisted.items.first { $0.recordName == newest }?.state, .pending,
                       "the newest member is checkpointed, so a resume brings it home")
    }

    /// A capture still waiting to upload into the album is copied home from its
    /// queue file, and its queue entry is cancelled rather than uploaded later into
    /// an album that no longer exists.
    func testAlbumMoveToLocalBringsHomeACaptureStillInTheUploadQueue() async throws {
        let queueDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitUploads-move-\(UUID().uuidString)", isDirectory: true)
        let queue = CloudKitUploadQueue(baseDir: queueDir)
        let fixture = try makeToLocalFixture(count: 1, uploadQueue: queue)
        defer {
            cleanup(fixture)
            try? FileManager.default.removeItem(at: queueDir)
        }
        let albumID = try XCTUnwrap(fixture.album.albumID)
        let captureID = UUID().uuidString
        let captureRecord = CloudKitFileAccess.componentRecordName(mediaID: captureID, type: .photo)
        let captureBytes = Data(repeating: 0xCD, count: 24)
        let captureFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(captureID).enc")
        try captureBytes.write(to: captureFile)
        try await queue.enqueue(CloudKitMediaUpload(albumID: albumID, mediaID: captureID, mediaType: .photo,
                                                    createdAt: Date(), sizeBytes: Int64(captureBytes.count),
                                                    encryptedFileURL: captureFile, encryptedThumbURL: nil,
                                                    recordName: captureRecord, keyFingerprint: ""))

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(try Data(contentsOf: fixture.localURL(captureID)), captureBytes,
                       "the queued capture lands in the local album byte for byte")
        let stillQueued = await queue.all()
        XCTAssertTrue(stillQueued.isEmpty, "its queue entry is cancelled")
        XCTAssertTrue(fixture.store.uploadCalls.isEmpty, "nothing is uploaded into the album on its way out")
        XCTAssertEqual(fixture.albumManager.finalizeToLocalMovedRecordNames.last,
                       Set(fixture.recordNames + [captureRecord]))
    }

    /// A record the server holds but this device's index never got (the reconcile
    /// read a feed without it) is found by the check before finalize and moved.
    func testAlbumMoveToLocalRecoversARecordMissingFromTheLocalIndex() async throws {
        let fixture = try makeToLocalFixture(count: 2)
        defer {
            CloudKitMigrationManager.boundaryHook = nil
            cleanup(fixture)
        }
        let albumID = try XCTUnwrap(fixture.album.albumID)
        fixture.store.nextChangeSets = [fixture.store.changeSet]
        let missingID = UUID().uuidString
        let missing = fixture.store.addServerRecord(albumID: albumID, mediaID: missingID)
        let plannedAtFirstItem = Box<Int?>(nil)
        let manager = fixture.manager
        CloudKitMigrationManager.boundaryHook = { boundary in
            guard plannedAtFirstItem.value == nil, case .transferred = boundary else { return }
            plannedAtFirstItem.value = manager.progress.totalCount
        }

        await fixture.manager.start(plan: fixture.plan)

        XCTAssertEqual(plannedAtFirstItem.value, 2, "precondition: the plan was built without the record")
        XCTAssertEqual(fixture.manager.state, .completed)
        XCTAssertEqual(try Data(contentsOf: fixture.localURL(missingID)), fixture.store.blobContents,
                       "the record missing from the index is brought home")
        XCTAssertTrue(fixture.store.deleteCalls.contains(missing))
        XCTAssertEqual(fixture.albumManager.finalizeToLocalCallCount, 1)
    }

    /// A saved album-scope plan gives its source and its destination a role, with no
    /// run in flight and without decrypting the plan; deleting the plan clears both.
    func testPlanRoleReportsBothEndsOfAPersistedMove() async throws {
        let album = makeAlbum(storage: .cloudKit)
        let local = Album.localTwin(of: album)
        let store = MigrationPlanStore(album: album)
        defer { try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: album)) }
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: album.id), .none)

        try await store.save(try MigrationPlan.album(album, items: []))

        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: album.id), .source(.toLocal, isRunning: false))
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: local.id), .destination(.toLocal, isRunning: false))
        XCTAssertFalse(MigrationPlanStore.planRole(forAlbumID: album.id).refusesNewMedia,
                       "a move that is not running refuses nothing")
        await store.delete()
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: album.id), .none)
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: local.id), .none)
    }

    /// Called directly, finalize refuses to delete an album record that still has a
    /// member the move did not remove, and leaves everything on this device as it was.
    func testFinalizeMigrationToLocalRefusesToDeleteANonEmptyAlbumRecord() async throws {
        let store = MockCloudKitMediaStore()
        let harness = makeTransportHarness(store: store)
        let albumID = UUID().uuidString
        let cloudAlbum = Album(name: "full-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                               key: harness.key, albumID: albumID)
        defer {
            cleanupCloudKitAlbum(albumID: albumID, key: harness.key, name: cloudAlbum.name)
            try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: cloudAlbum))
        }
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: false).write(albumID: albumID)
        try await AlbumSizeSidecar(album: cloudAlbum).apply(updates: ["kept#0": 1])
        let remainingID = UUID().uuidString
        _ = try await MediaIndexStore(album: cloudAlbum).upsert([
            MediaIndexEntry(id: remainingID, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: nil, dateTaken: Date(), subtypeRawValue: 0)
        ])
        let cacheDir = CloudKitStorageModel(album: cloudAlbum).baseURL
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data([1]).write(to: cacheDir.appendingPathComponent("cached.bin"))
        let moved = store.addServerRecord(albumID: albumID)
        let remaining = store.addServerRecord(albumID: albumID, mediaID: remainingID)

        do {
            _ = try await harness.albumManager.finalizeMigrationToLocal(album: cloudAlbum, movedRecordNames: [moved])
            XCTFail("finalize must refuse while a member it did not move points at the album")
        } catch AlbumError.albumStillHasMembers {
        }

        XCTAssertTrue(store.deletedAlbumCalls.isEmpty, "the album record is not deleted")
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: albumID), "album.json is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: MediaIndexStore.indexURL(for: cloudAlbum).path),
                      "the index is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("cached.bin").path),
                      "the blob cache is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AlbumSizeSidecar.sidecarURL(for: cloudAlbum).path))

        _ = try await harness.albumManager.finalizeMigrationToLocal(album: cloudAlbum,
                                                                     movedRecordNames: [moved, remaining])
        XCTAssertEqual(store.deletedAlbumCalls, [albumID], "with every member moved, the record goes")
    }
}
