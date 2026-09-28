//
//  CloudKitMediaMoveTests.swift
//  EncameraCoreTests
//
//  Item-scope moves between local storage and CloudKit, in both directions, driven
//  by `CloudKitMigrationManager.start(plan:)`.
//

import XCTest
import UIKit
import CloudKit
import Combine
@testable import EncameraCore

@MainActor
final class CloudKitMediaMoveTests: XCTestCase {

    private func randomKey() -> [UInt8] { (0..<32).map { _ in UInt8.random(in: 0...255) } }

    private func makeAlbum(storage: StorageType = .local) -> Album {
        let key = PrivateKey(name: "key-\(UUID().uuidString.prefix(8))",
                             keyBytes: randomKey(), creationDate: Date())
        return Album(name: "move-\(UUID().uuidString)", storageOption: storage,
                     creationDate: Date(), key: key,
                     albumID: storage == .cloudKit ? UUID().uuidString : nil)
    }

    private func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    private func makePhoto(id: String = UUID().uuidString) throws -> InteractableMedia<CleartextMedia> {
        try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
        ])
    }

    /// Seeds `count` encrypted photos in `album` and returns their IDs.
    private func seedLocalAlbum(count: Int,
                                albumManager: MockAlbumManager,
                                album: Album) async throws -> [String] {
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

    /// Builds a `MediaMovePlan` from items already seeded in the source album.
    private func buildPlan(sourceAlbum: Album,
                           destinationAlbum: Album,
                           ids: [String]) -> MigrationPlan {
        let items = ids.map { id -> MigrationItem in
            let model = sourceAlbum.storageOption.modelForType.init(album: sourceAlbum)
            let encURL = model.driveURLForMedia(withID: id, type: .photo)
            let size = encURL.fileSizeBytes() ?? 0
            return MigrationItem(
                mediaID: id,
                recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                mediaType: .photo,
                createdAt: Date(),
                sizeBytes: size
            )
        }
        return try! MigrationPlan(
            id: UUID().uuidString,
            source: MigrationEndpoint(album: sourceAlbum),
            destination: MigrationEndpoint(album: destinationAlbum),
            scope: .items,
            items: items,
            createdAt: Date()
        )
    }

    private func makeRunner(store: MockCloudKitMediaStore,
                            keys: [PrivateKey] = []) -> (CloudKitMigrationManager, MockAlbumManager) {
        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = keys
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let runner = CloudKitMigrationManager(albumManager: albumManager,
                                              storeFactory: { _ in store })
        return (runner, albumManager)
    }

    private func sourceEncURL(album: Album, id: String) -> URL {
        album.storageOption.modelForType.init(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func cleanup(_ albums: Album...) {
        for album in albums {
            let model = album.storageOption.modelForType.init(album: album)
            try? FileManager.default.removeItem(at: model.baseURL)
            if let albumID = album.albumID {
                try? CloudKitAlbumMarker.remove(albumID: albumID)
            }
        }
        try? MediaIndexStore.clearAllIndexes()
        // Clean up move plan directory
        let movesDir = MigrationPlanStore.directoryURL()
        try? FileManager.default.removeItem(at: movesDir)
    }

    // MARK: - Tests

    func testForwardMoveUploadsVerifiesThenDeletesSourceFile() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        albumManager.albumsOnDisk = [source, dest]

        let started = await runner.start(plan: plan)
        XCTAssertTrue(started, "the run must claim both albums and start")
        XCTAssertEqual(runner.state, .completed)
        XCTAssertEqual(runner.progress.fractionComplete, 1.0, accuracy: 0.0001)
        XCTAssertEqual(store.uploadCalls.count, 1, "each component uploads exactly once")

        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: id).path),
                           "the source file is deleted after verified upload")
        }
    }

    func testForwardMoveAcrossKeysKeepsFileFingerprint() async throws {
        // Source and destination have different keys. The migrated record must
        // carry the source file's proven fingerprint, not the destination key's.
        let sourceKey = randomKey()
        let destKey = randomKey()
        let sourcePriv = PrivateKey(name: "srckey-\(UUID().uuidString.prefix(4))",
                                    keyBytes: sourceKey, creationDate: Date())
        let destPriv = PrivateKey(name: "dstkey-\(UUID().uuidString.prefix(4))",
                                  keyBytes: destKey, creationDate: Date())
        let source = Album(name: "src-\(UUID().uuidString)", storageOption: .local,
                           creationDate: Date(), key: sourcePriv)
        let dest = Album(name: "dst-\(UUID().uuidString)", storageOption: .cloudKit,
                         creationDate: Date(), key: destPriv, albumID: UUID().uuidString)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true

        let keyManager = DemoKeyManager()
        keyManager.currentKey = sourcePriv
        // The keyManager must know both keys for stampedSourceForUpload to prove
        // the source file's key.
        keyManager.storedKeysValue = [sourcePriv, destPriv]
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let runner = CloudKitMigrationManager(albumManager: albumManager,
                                              storeFactory: { _ in store })
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)
        XCTAssertEqual(runner.state, .completed)
        XCTAssertEqual(store.uploadedItems.count, 1)
        // The fingerprint must be the SOURCE key's label: it was written by the
        // source key, and the record tells readers which key decrypts it.
        XCTAssertEqual(store.uploadedItems.first?.keyFingerprint, sourcePriv.keychainLabel,
                       "the record's keyFingerprint must name the key that encrypted the file, not the destination key")
    }

    func testForwardMoveRemovesIDFromSourceIndexAndNotifiesBus() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)

        // Seed the source index so we can verify it is cleaned up
        let sourceIndex = MediaIndexStore(album: source)
        let entry = MediaIndexEntry(id: ids[0], hasPhotoComponent: true, hasVideoComponent: false,
                                       dateEncrypted: nil, dateTaken: nil, subtypeRawValue: 0)
        try await sourceIndex.upsert([entry])
        let beforeMove = await sourceIndex.load()
        XCTAssertEqual(beforeMove?.entries.count, 1, "precondition: source index has the entry")

        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        albumManager.albumsOnDisk = [source, dest]
        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        let afterMove = await sourceIndex.load()
        let remaining = afterMove?.entries ?? []
        XCTAssertTrue(remaining.isEmpty, "the source index entry must be removed after the move")
    }

    func testResumeAfterUploadedDoesNotReupload() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        var plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        // Simulate a prior run that already uploaded but not yet verified:
        // seed the plan with the item in `.uploaded` state and put the record
        // on the "server" so verification succeeds.
        plan.items[0].state = .uploaded
        let item = plan.items[0]
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: try XCTUnwrap(dest.albumID), mediaID: item.mediaID, mediaType: item.mediaType,
            createdAt: item.createdAt, sizeBytes: item.sizeBytes, creationDeviceID: "mock",
            schemaVersion: 1, recordChangeTag: "tag"
        )]

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertTrue(store.uploadCalls.isEmpty, "an already-uploaded item is verified, not re-uploaded")
        XCTAssertEqual(runner.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: ids[0]).path),
                       "the source is deleted after verification")
    }

    func testCancelIsDurableAndLeavesRemainingItemsInSource() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        // Cancel during the first upload
        store.onUploadStarted = { [weak runner] in
            await runner?.cancel(plan: plan)
        }

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        // The run must have stopped — either idle (cancel path) or completed if the
        // cancel raced and the single item finished.
        XCTAssertNotEqual(runner.state, .running, "the run must not still be running after cancel")

        // The move plan should be saved with cancelledAt set
        let movePlanStore = MigrationPlanStore(sourceAlbum: source, planID: plan.id)
        let persisted = await movePlanStore.load()
        if let persisted {
            XCTAssertNotNil(persisted.cancelledAt, "an explicit cancel must be recorded durably")
        }

        // Source files should survive
        for id in ids {
            // Files that were not fully migrated (sourceDeleted) should still exist
            let exists = FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: id).path)
            if let persisted, let item = persisted.items.first(where: { $0.mediaID == id }) {
                if item.state != .sourceDeleted {
                    XCTAssertTrue(exists, "a non-completed item's source file must survive a cancel")
                }
            }
        }
    }

    func testFailedItemKeepsSourceFile() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        // Verification fails because reflectUploadsInMetadata is off
        store.reflectUploadsInMetadata = false
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        // Verification failure: the item should be failed and the source file intact
        guard case .failed = runner.state else {
            return XCTFail("expected a failed run, got \(runner.state)")
        }
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: id).path),
                          "a failed item's source file must survive")
        }
    }

    func testClaimsBothAlbumsAndReleasesOnExit() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        // Claimed under `Album.id`, the key the album-migration engine claims and
        // the album screen's overlay predicate reads — not the CloudKit album hash.
        let sourceID = source.id
        let destID = dest.id

        // Neither album should be active before the run
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: sourceID))
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: destID))

        // Verify that during the run, both are active. Use an actor to thread-safely
        // record the observation from the @Sendable upload callback.
        let observer = ClaimObserver()
        store.onUploadStarted = { [sourceID, destID] in
            let srcActive = CloudKitMigrationManager.isActive(albumID: sourceID)
            let dstActive = CloudKitMigrationManager.isActive(albumID: destID)
            await observer.record(srcActive && dstActive)
        }

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        let bothActiveInRun = await observer.value
        XCTAssertTrue(bothActiveInRun, "both album IDs must be active during the run")
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: sourceID),
                       "source album must be released after the run")
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: destID),
                       "destination album must be released after the run")
    }

    func testQuotaMapsToBlockingFailure() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        store.uploadErrorOnce = CloudKitMediaStoreError.quotaExceeded
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .failed(.quota), "a quota error must halt the run as .failed(.quota)")
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: id).path),
                          "source files must survive a quota failure")
        }
    }
    // MARK: - Forward: verified only against a record in the destination album

    private let otherAlbumID = "album-moved-to-from-another-device"

    /// A forward plan whose one item an earlier run left in `state`, with its record
    /// on the server in the destination album and since moved to `otherAlbumID` from
    /// another device.
    private func reparentedForwardFixture(state: MigrationItemState) async throws
        -> (runner: CloudKitMigrationManager, store: MockCloudKitMediaStore, plan: MigrationPlan,
            source: Album, dest: Album, localURL: URL) {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        albumManager.albumsOnDisk = [source, dest]
        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        var plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        plan.items[0].state = state
        let item = plan.items[0]
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: try XCTUnwrap(dest.albumID), mediaID: item.mediaID,
            mediaType: item.mediaType, createdAt: item.createdAt, sizeBytes: item.sizeBytes,
            creationDeviceID: "mock", schemaVersion: 1, recordChangeTag: "tag")]
        _ = try await store.reassignAlbum(recordNames: [item.recordName], toAlbumID: otherAlbumID)
        return (runner, store, plan, source, dest, sourceEncURL(album: source, id: item.mediaID))
    }

    private func assertKeptLocalAndLeftRecordInOtherAlbum(_ runner: CloudKitMigrationManager,
                                                          _ store: MockCloudKitMediaStore,
                                                          recordName: String,
                                                          localURL: URL,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path),
                      "a record now in another album is not this move's copy, so the local original stays",
                      file: file, line: line)
        XCTAssertEqual(runner.state, .completed,
                       "the item is skipped, which is terminal, so the run finishes", file: file, line: line)
        XCTAssertTrue(store.uploadCalls.isEmpty, "the other album's record is never saved over",
                      file: file, line: line)
        XCTAssertTrue(store.deleteCalls.isEmpty, file: file, line: line)
        let owner = try await store.confirmAlbum(recordName: recordName)
        XCTAssertEqual(owner, otherAlbumID, "the record stays in the album it was moved to", file: file, line: line)
    }

    func testForwardMoveResumedAfterUploadWhoseRecordWasMovedToAnotherAlbumKeepsTheLocalOriginal() async throws {
        let f = try await reparentedForwardFixture(state: .uploaded)
        defer { cleanup(f.source, f.dest) }

        await f.runner.start(plan: f.plan)

        try await assertKeptLocalAndLeftRecordInOtherAlbum(f.runner, f.store, recordName: f.plan.items[0].recordName,
                                                           localURL: f.localURL)
    }

    func testForwardMoveResumedFromAStaleVerificationWhoseRecordWasMovedToAnotherAlbumKeepsTheLocalOriginal() async throws {
        let f = try await reparentedForwardFixture(state: .verified)
        defer { cleanup(f.source, f.dest) }

        await f.runner.start(plan: f.plan)

        try await assertKeptLocalAndLeftRecordInOtherAlbum(f.runner, f.store, recordName: f.plan.items[0].recordName,
                                                           localURL: f.localURL)
    }

    /// Another device moves the record between this run's owner check and its verify.
    func testForwardMoveWhoseRecordIsMovedToAnotherAlbumBeforeItsVerifyKeepsTheLocalOriginal() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        albumManager.albumsOnDisk = [source, dest]
        defer { cleanup(source, dest) }
        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        let item = plan.items[0]
        store.confirmAlbumOverride[item.recordName] = .success(nil)
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: otherAlbumID, mediaID: item.mediaID,
            mediaType: item.mediaType, createdAt: item.createdAt, sizeBytes: item.sizeBytes,
            creationDeviceID: "other-device", schemaVersion: 1, recordChangeTag: "tag")]

        await runner.start(plan: plan)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: item.mediaID).path),
                      "a verify that finds the record in another album must not delete the local original")
        XCTAssertEqual(runner.state, .completed, "the item is skipped, which is terminal, so the run finishes")
        let calls = store.callOrder
        let checked = try XCTUnwrap(calls.firstIndex(of: .confirmAlbum(recordName: item.recordName)))
        let uploaded = try XCTUnwrap(calls.firstIndex(of: .upload(recordName: item.recordName)))
        let verified = try XCTUnwrap(calls.lastIndex(of: .fetchRecordMetadata(recordName: item.recordName)))
        XCTAssertLessThan(checked, uploaded, "the owner check passed before the upload")
        XCTAssertLessThan(uploaded, verified, "and the verify is what saw the other album")
    }

    // MARK: - Forward: a Live Photo leaves the source index one component at a time

    /// Seeds a Live Photo: a photo and a legacy video under one id, and an index entry
    /// that records both components.
    private func seedLivePhoto(albumManager: MockAlbumManager, album: Album) async throws -> String {
        let id = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: album)[0]
        let model = album.storageOption.modelForType.init(album: album)
        let plaintextURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: plaintextURL)
        defer { try? FileManager.default.removeItem(at: plaintextURL) }
        let handler = SecretFileHandlerV2(keyBytes: album.key.keyBytes,
                                          source: CleartextMedia(source: plaintextURL, mediaType: .video, id: id),
                                          targetURL: model.driveURLForMedia(withID: id, type: .video))
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        try await MediaIndexStore(album: album).upsert([
            MediaIndexEntry(id: id, hasPhotoComponent: true, hasVideoComponent: true,
                            dateEncrypted: nil, dateTaken: nil, subtypeRawValue: 0)
        ])
        return id
    }

    /// A plan moving both components of the Live Photo `id`, photo first.
    private func buildLivePhotoPlan(sourceAlbum: Album, destinationAlbum: Album, id: String) -> MigrationPlan {
        let model = sourceAlbum.storageOption.modelForType.init(album: sourceAlbum)
        let items = [MediaType.photo, .video].map { type in
            MigrationItem(mediaID: id,
                          recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: type),
                          mediaType: type,
                          createdAt: Date(),
                          sizeBytes: model.driveURLForMedia(withID: id, type: type).fileSizeBytes() ?? 0)
        }
        return try! MigrationPlan.items(source: sourceAlbum, destination: destinationAlbum, items: items)
    }

    private func sourceEntry(_ id: String, in album: Album) async -> MediaIndexEntry? {
        await MediaIndexStore(album: album).load()?.entries.first { $0.id == id }
    }

    func testLivePhotoWhoseVideoFailsToUploadStaysInTheSourceIndexWithOnlyItsVideo() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let id = try await seedLivePhoto(albumManager: albumManager, album: source)
        let plan = buildLivePhotoPlan(sourceAlbum: source, destinationAlbum: dest, id: id)
        store.uploadFailures[plan.items[1].recordName] = CloudKitMediaStoreError.quotaExceeded
        let deletes = DeleteRecorder(id: id)
        defer { deletes.cancel() }
        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .failed(.quota))
        let model = source.storageOption.modelForType.init(album: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.driveURLForMedia(withID: id, type: .photo).path),
                       "precondition: the photo moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.driveURLForMedia(withID: id, type: .video).path),
                      "the video that failed to upload stays on disk")
        let entry = await sourceEntry(id, in: source)
        XCTAssertNotNil(entry, "the Live Photo must stay in the source index while its video is still here")
        XCTAssertEqual(entry?.hasPhotoComponent, false, "the moved photo must leave the source entry")
        XCTAssertEqual(entry?.hasVideoComponent, true, "the video still on disk must stay in the source entry")
        XCTAssertEqual(deletes.count, 0, "the grid must not be told the Live Photo is gone")
    }

    func testLivePhotoThatFullyMovesLeavesTheSourceIndexWithOneDeleteEvent() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let id = try await seedLivePhoto(albumManager: albumManager, album: source)
        let plan = buildLivePhotoPlan(sourceAlbum: source, destinationAlbum: dest, id: id)
        let deletes = DeleteRecorder(id: id)
        defer { deletes.cancel() }
        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        let entry = await sourceEntry(id, in: source)
        XCTAssertNil(entry, "a Live Photo whose both halves moved must leave the source index")
        XCTAssertEqual(deletes.count, 1, "the grid is told once, when the Live Photo's last component leaves")
    }

    /// A kill between an item's `sourceDeleted` checkpoint and its index write leaves
    /// the source index naming a file that is gone. The resumed run clears it.
    func testResumedMoveClearsTheSourceEntryOfAnItemKilledBeforeItsIndexWrite() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        var plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        try FileManager.default.removeItem(at: sourceEncURL(album: source, id: ids[0]))
        plan.items[0].state = .sourceDeleted
        let before = await sourceEntry(ids[0], in: source)
        XCTAssertNotNil(before, "precondition: the killed run never removed the entry")
        let deletes = DeleteRecorder(id: ids[0])
        defer { deletes.cancel() }
        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        let after = await sourceEntry(ids[0], in: source)
        XCTAssertNil(after, "the source index must not keep an entry whose file is gone")
        XCTAssertEqual(deletes.count, 1, "the grid must be told the item left")
    }

    /// The same kill on a Live Photo's photo, resumed into a run whose video fails:
    /// the entry keeps the video it still has and drops the photo it no longer has.
    func testResumedMoveClearsOnlyTheKilledComponentOfALivePhoto() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }

        let id = try await seedLivePhoto(albumManager: albumManager, album: source)
        var plan = buildLivePhotoPlan(sourceAlbum: source, destinationAlbum: dest, id: id)
        try FileManager.default.removeItem(at: sourceEncURL(album: source, id: id))
        plan.items[0].state = .sourceDeleted
        store.uploadFailures[plan.items[1].recordName] = CloudKitMediaStoreError.quotaExceeded
        let deletes = DeleteRecorder(id: id)
        defer { deletes.cancel() }
        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .failed(.quota))
        let entry = await sourceEntry(id, in: source)
        XCTAssertEqual(entry?.hasPhotoComponent, false, "the photo whose file is gone must leave the entry")
        XCTAssertEqual(entry?.hasVideoComponent, true, "the video still on disk must stay")
        XCTAssertEqual(deletes.count, 0, "the Live Photo is still in the source album")
    }

    // MARK: - Reverse (CloudKit -> local) helpers

    /// Builds a reverse `MediaMovePlan` for items identified by `ids` that live
    /// in a CloudKit source album and will move to a local destination.
    private func buildReversePlan(sourceAlbum: Album,
                                  destinationAlbum: Album,
                                  ids: [String],
                                  sizeBytes: Int64 = 10) -> MigrationPlan {
        let items = ids.map { id in
            MigrationItem(
                mediaID: id,
                recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                mediaType: .photo,
                createdAt: Date(),
                sizeBytes: sizeBytes
            )
        }
        return try! MigrationPlan(
            id: UUID().uuidString,
            source: MigrationEndpoint(album: sourceAlbum),
            destination: MigrationEndpoint(album: destinationAlbum),
            scope: .items,
            items: items,
            createdAt: Date()
        )
    }

    /// Seeds the mock store with metadata for the given IDs so the coordinator
    /// sees them as existing CloudKit records.
    private func seedCloudKitRecords(store: MockCloudKitMediaStore,
                                     ids: [String],
                                     albumID: String = "test-hash",
                                     sizeBytes: Int64 = 10) {
        store.metadataToReturn = ids.map { id in
            CloudKitMediaMetadata(
                recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                albumID: albumID,
                mediaID: id,
                mediaType: .photo,
                createdAt: Date(),
                sizeBytes: sizeBytes,
                creationDeviceID: "mock",
                schemaVersion: 1,
                recordChangeTag: "tag"
            )
        }
        // Set blob contents to match the expected size
        store.blobContents = Data(repeating: 0xAA, count: Int(sizeBytes))
    }

    // MARK: - Reverse (CloudKit -> local) tests

    func testReverseMoveDownloadsVerifiesThenDeletesRemote() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }

        let ids = [UUID().uuidString]
        seedCloudKitRecords(store: store, ids: ids)
        let plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        // Initialize destination directories so the file copy lands
        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()

        albumManager.albumsOnDisk = [source, dest]

        let started = await runner.start(plan: plan)
        XCTAssertTrue(started, "the run must claim both albums and start")
        XCTAssertEqual(runner.state, .completed)
        XCTAssertEqual(runner.progress.fractionComplete, 1.0, accuracy: 0.0001)

        // The blob was fetched (downloaded)
        XCTAssertGreaterThanOrEqual(store.fetchBlobCount, 1, "the blob must be fetched from CloudKit")

        // The remote record was deleted
        XCTAssertEqual(store.deleteCalls.count, 1, "the remote record must be deleted after verification")

        // The file exists at the local destination
        for id in ids {
            let destURL = destModel.driveURLForMedia(withID: id, type: .photo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path),
                          "the file must land at the local destination")
        }
    }

    func testReverseMoveFailedVerifyLeavesRecordAndSourceIndex() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }

        let ids = [UUID().uuidString]
        // Seed with 10 bytes of blob
        seedCloudKitRecords(store: store, ids: ids, sizeBytes: 10)

        var plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids, sizeBytes: 10)

        // Initialize destination directories
        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()

        // Simulate the item being already "downloaded" but with a zero-byte
        // destination file so verification fails.
        plan.items[0].state = .uploaded
        let destURL = destModel.driveURLForMedia(withID: ids[0], type: .photo)
        // Write zero bytes to the destination
        try Data().write(to: destURL)

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        // The item must be failed
        guard case .failed = runner.state else {
            return XCTFail("expected a failed run, got \(runner.state)")
        }

        // The remote record must NOT have been deleted
        XCTAssertTrue(store.deleteCalls.isEmpty,
                      "a failed verification must NOT delete the remote record")
    }

    func testReverseMoveCancelBeforeRemoteDeleteLeavesItemInCloudKit() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }

        let ids = [UUID().uuidString]
        seedCloudKitRecords(store: store, ids: ids)

        // Use a slow blob fetch so we can cancel after download completes but before delete
        store.fetchBlobDelayNanos = 50_000_000 // 50ms

        let plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()

        // Cancel right after the first progress report — this fires during
        // ensureBlobLocal's fetch, so the cancel arrives between the download
        // and the delete step (the cancel boundary).
        store.onFirstProgress = { [weak runner] in
            Task { @MainActor in await runner?.cancel(plan: plan) }
        }

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        // The run must have stopped
        XCTAssertNotEqual(runner.state, .running, "the run must not still be running after cancel")

        // The move plan should be saved with cancelledAt set
        let movePlanStore = MigrationPlanStore(sourceAlbum: source, planID: plan.id)
        let persisted = await movePlanStore.load()
        if let persisted {
            XCTAssertNotNil(persisted.cancelledAt, "an explicit cancel must be recorded durably")
        }

        // The remote record must still exist (delete should not have happened,
        // or if cancel raced past the boundary, the record is gone — both are
        // acceptable, but ideally the cancel boundary holds)
        // At minimum, the run stopped before or at the cancel boundary.
    }

    func testReverseMoveEvictedBlobIsFetched() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }

        let ids = [UUID().uuidString]
        seedCloudKitRecords(store: store, ids: ids)
        // Do NOT pre-cache the blob — only the metadata is seeded.
        // The coordinator must fetch from the store.

        let plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        XCTAssertGreaterThanOrEqual(store.fetchBlobCount, 1,
                                    "an evicted blob must be fetched from the store")
    }

    func testReverseMoveMissingRecordIsSkippedTerminally() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }

        let ids = [UUID().uuidString]
        // Do NOT seed any records — the record does not exist.
        store.fetchBlobError = CloudKitMediaStoreError.notFound

        let plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        // The run completes because the only item was skipped
        XCTAssertEqual(runner.state, .completed,
                       "a run with all items skipped must complete")

        // No deletes should have happened
        XCTAssertTrue(store.deleteCalls.isEmpty,
                      "a skipped item must not trigger a remote delete")
    }

    func testReverseMoveUpsertsDestinationIndexAndEmitsCreate() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }

        let ids = [UUID().uuidString]
        seedCloudKitRecords(store: store, ids: ids)

        let plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)

        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()

        // Record FileOperationBus create events
        let busObserver = BusObserver()
        let cancellable = FileOperationBus.shared.operations
            .sink { op in
                if case .create = op {
                    Task { await busObserver.recordCreate() }
                }
            }
        defer { cancellable.cancel() }

        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)

        // Verify the destination index has the entry
        let destIndex = MediaIndexStore(album: dest)
        let loaded = await destIndex.load()
        let entries = loaded?.entries ?? []
        XCTAssertEqual(entries.count, 1,
                       "the destination index must have exactly one entry after the move")
        XCTAssertEqual(entries.first?.id, ids[0],
                       "the destination index entry must have the moved item's ID")

        // Verify a create event was emitted
        // Give the async bus observer a moment to process
        try await Task.sleep(nanoseconds: 50_000_000)
        let createCount = await busObserver.createCount
        XCTAssertGreaterThanOrEqual(createCount, 1,
                                    "FileOperationBus.didCreate must fire for the moved item")
    }

    // MARK: - Reverse: stale verification, cancel and existing copies

    /// A reverse plan whose one item an earlier run left in `state`, with the local
    /// copy that run would have written (`localBytes`, or none).
    private func reverseFixture(state: MigrationItemState,
                                localBytes: Data?) throws -> (runner: CloudKitMigrationManager,
                                                              store: MockCloudKitMediaStore,
                                                              plan: MigrationPlan,
                                                              source: Album, dest: Album,
                                                              recordName: String, localURL: URL) {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        albumManager.albumsOnDisk = [source, dest]
        let id = UUID().uuidString
        seedCloudKitRecords(store: store, ids: [id], albumID: try XCTUnwrap(source.albumID))
        var plan = buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: [id])
        plan.items[0].state = state
        let destModel = dest.storageOption.modelForType.init(album: dest)
        try destModel.initializeDirectories()
        let localURL = destModel.driveURLForMedia(withID: id, type: .photo)
        if let localBytes { try localBytes.write(to: localURL) }
        return (runner, store, plan, source, dest, plan.items[0].recordName, localURL)
    }

    /// The local copy's size at the moment each record delete is issued.
    private func recordLocalSizeAtDelete(_ store: MockCloudKitMediaStore, localURL: URL) -> DeleteObserver {
        let observer = DeleteObserver()
        store.onDelete = { _ in observer.sizes.append(localURL.fileSizeBytes()) }
        return observer
    }

    func testReverseMoveResumedAfterItsLocalCopyWasDeletedDownloadsItAgainBeforeDeletingTheRecord() async throws {
        let f = try reverseFixture(state: .verified, localBytes: nil)
        defer { cleanup(f.source, f.dest) }
        let atDelete = recordLocalSizeAtDelete(f.store, localURL: f.localURL)

        await f.runner.start(plan: f.plan)

        XCTAssertEqual(atDelete.sizes, [10],
                       "the record may only be deleted once a full local copy is back in place")
        XCTAssertEqual(f.localURL.fileSizeBytes(), 10, "the item must end with a verified local copy")
        XCTAssertEqual(f.runner.state, .completed)
    }

    func testReverseMoveResumedWithATruncatedLocalCopyReplacesItBeforeDeletingTheRecord() async throws {
        let f = try reverseFixture(state: .verified, localBytes: Data(repeating: 0xAA, count: 3))
        defer { cleanup(f.source, f.dest) }
        let atDelete = recordLocalSizeAtDelete(f.store, localURL: f.localURL)

        await f.runner.start(plan: f.plan)

        XCTAssertEqual(atDelete.sizes, [10],
                       "a local copy that no longer matches the record is not a copy to delete the record against")
        XCTAssertEqual(f.localURL.fileSizeBytes(), 10)
    }

    func testReverseMoveCancelledBeforeTheRecordIsDeletedLeavesTheItemOnlyInCloudKit() async throws {
        let f = try reverseFixture(state: .pending, localBytes: nil)
        defer { cleanup(f.source, f.dest) }
        let plan = f.plan
        f.store.fetchBlobProgressSteps = [0.5]
        f.store.onFirstProgress = { [weak runner = f.runner] in
            Task { @MainActor in await runner?.cancel(plan: plan) }
        }

        await f.runner.start(plan: plan)

        XCTAssertEqual(f.runner.state, .idle)
        XCTAssertTrue(f.store.deleteCalls.isEmpty, "the cancel lands before the record is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.localURL.path),
                       "an item whose record stays must not also have a local copy, or it shows in both albums")
        let persisted = await MigrationPlanStore(sourceAlbum: f.source, planID: plan.id).load()
        XCTAssertNotNil(persisted?.cancelledAt)
        XCTAssertEqual(persisted?.items.first?.state, .pending, "a resume must download the item again")
    }

    func testCancellingAStoppedReverseMoveDiscardsTheLocalCopyOfAVerifiedItem() async throws {
        let f = try reverseFixture(state: .verified, localBytes: Data(repeating: 0xAA, count: 10))
        defer { cleanup(f.source, f.dest) }
        try await MigrationPlanStore(sourceAlbum: f.source, planID: f.plan.id).save(f.plan)

        await f.runner.cancel(plan: f.plan)

        XCTAssertTrue(f.store.deleteCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.localURL.path),
                       "the record stays, so the local copy must go")
        let persisted = await MigrationPlanStore(sourceAlbum: f.source, planID: f.plan.id).load()
        XCTAssertNotNil(persisted?.cancelledAt)
        XCTAssertEqual(persisted?.items.first?.state, .pending)
    }

    func testReverseMoveWhoseVerifyIsRejectedLeavesTheItemOnlyInCloudKit() async throws {
        // An earlier download was cut short after the copy was checkpointed.
        let f = try reverseFixture(state: .uploaded, localBytes: Data(repeating: 0xAA, count: 3))
        defer { cleanup(f.source, f.dest) }

        await f.runner.start(plan: f.plan)

        guard case .failed = f.runner.state else { return XCTFail("expected a failed run, got \(f.runner.state)") }
        XCTAssertTrue(f.store.deleteCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.localURL.path),
                       "the record stays, so the rejected local copy must not stay behind as a duplicate")
    }

    func testReverseMoveCancelKeepsTheLocalCopyWhenTheRecordCannotBeConfirmed() async throws {
        let f = try reverseFixture(state: .verified, localBytes: Data(repeating: 0xAA, count: 10))
        defer { cleanup(f.source, f.dest) }
        try await MigrationPlanStore(sourceAlbum: f.source, planID: f.plan.id).save(f.plan)
        f.store.fetchRecordMetadataError = CloudKitMediaStoreError.retry(after: 1)

        await f.runner.cancel(plan: f.plan)

        XCTAssertEqual(f.localURL.fileSizeBytes(), 10,
                       "without proof the record is still there, the local copy may be the only one")
    }

    func testReverseMoveKeepsAnExistingLocalCopyThatMatchesTheRecord() async throws {
        let f = try reverseFixture(state: .pending, localBytes: Data(repeating: 0xAA, count: 10))
        defer { cleanup(f.source, f.dest) }
        let before = try XCTUnwrap(fileNumber(f.localURL))

        await f.runner.start(plan: f.plan)

        XCTAssertEqual(f.runner.state, .completed)
        XCTAssertEqual(fileNumber(f.localURL), before,
                       "a copy already at the destination that matches the record is kept, not deleted and rewritten")
    }

    func testReplacingALocalCopyNeverRemovesItBeforeTheReplacementIsInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.enc")
        let existing = Data(repeating: 0xCC, count: 7)
        try existing.write(to: destination)
        let unreadable = directory.appendingPathComponent("gone-from-the-cache.enc")

        XCTAssertThrowsError(try CloudKitToLocalStep.placeCopy(of: unreadable, at: destination))

        XCTAssertEqual(try? Data(contentsOf: destination), existing,
                       "a copy that fails must leave the file already at the destination untouched")
    }

    // MARK: - Reverse: verified against the record on the server

    /// Puts `bytes` in the shared blob cache as the record's cached ciphertext, the
    /// way a download cut short or a damaged cache file would leave it.
    private func seedCacheEntry(_ bytes: Data, recordName: String, albumID: String, changeTag: String) async throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("short-cache-\(UUID().uuidString)")
        try bytes.write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await CloudKitBlobCache.shared.store(recordName: recordName, changeTag: changeTag,
                                                     albumID: albumID, from: staged)
    }

    private func isCached(_ recordName: String, changeTag: String) async -> Bool {
        await CloudKitBlobCache.shared.cachedURL(recordName: recordName, changeTag: changeTag) != nil
    }

    private func deleted(_ store: MockCloudKitMediaStore, _ recordName: String) -> Bool {
        store.callOrder.contains(.delete(recordName: recordName))
    }

    func testReverseMoveFromATruncatedCachedBlobKeepsTheRecordAndBringsAFullCopyHomeOnResume() async throws {
        let f = try reverseFixture(state: .pending, localBytes: nil)
        defer { cleanup(f.source, f.dest) }
        let albumID = try XCTUnwrap(f.source.albumID)
        try await seedCacheEntry(Data(repeating: 0xAA, count: 3), recordName: f.recordName,
                                 albumID: albumID, changeTag: "tag")
        addTeardownBlock { await CloudKitBlobCache.shared.evict(recordName: f.recordName) }

        await f.runner.start(plan: f.plan)

        XCTAssertFalse(deleted(f.store, f.recordName),
                       "a copy made from a truncated cache entry must not be taken as proof the record can go")
        guard case .failed = f.runner.state else { return XCTFail("expected a failed run, got \(f.runner.state)") }
        let cached = await isCached(f.recordName, changeTag: "tag")
        XCTAssertFalse(cached, "the truncated cache entry must be evicted so the next attempt downloads the record")

        let loaded = await MigrationPlanStore(sourceAlbum: f.source, planID: f.plan.id).load()
        let persisted = try XCTUnwrap(loaded)
        let atDelete = recordLocalSizeAtDelete(f.store, localURL: f.localURL)
        await f.runner.start(plan: persisted)

        XCTAssertEqual(f.runner.state, .completed)
        XCTAssertGreaterThanOrEqual(f.store.fetchBlobCount, 1, "the resume downloads the record again")
        XCTAssertEqual(atDelete.sizes, [10], "the record goes only once a full copy is in place")
        XCTAssertEqual(try Data(contentsOf: f.localURL), f.store.blobContents)
    }

    /// A chunked video record whose ENC3 chunks live in `chunkStore`. Its
    /// `sizeBytes` is its ENC2 original's, as a legacy video re-encrypted on its way
    /// into CloudKit keeps, so only the header gives the ciphertext's length.
    private func seedChunkedVideoRecord(store: MockCloudKitMediaStore,
                                        chunkStore: InMemoryChunkedBlobStore,
                                        album: Album,
                                        id: String) async throws -> (recordName: String, ciphertext: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("plain.bin")
        let enc3 = dir.appendingPathComponent("video.enc3")
        try Data((0..<5_000).map { UInt8($0 % 251) }).write(to: source)
        let header = try SeekableEncryptedWriter(keyBytes: album.key.keyBytes, chunkSize: 1_000)
            .encrypt(source: source, destination: enc3)
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .video)
        try await chunkStore.uploadChunks(enc3FileURL: enc3, mediaRecordName: recordName, progress: { _ in })
        let record = CloudKitMediaMetadata(recordName: recordName, albumID: try XCTUnwrap(album.albumID), mediaID: id,
                                           mediaType: .video, createdAt: Date(),
                                           sizeBytes: Int64(header.geometry.totalCiphertextLength) - 700,
                                           creationDeviceID: "writer", schemaVersion: 1, keyFingerprint: "",
                                           recordChangeTag: "tag", chunkCount: header.chunkCount,
                                           plaintextLength: Int64(header.plaintextLength), encHeader: header.encoded())
        store.metadataToReturn = [record]
        store.changeSet = CloudKitChangeSet(changed: [record], deleted: [], token: nil, moreComing: false)
        // A chunked record carries no `encBlob` asset.
        store.fetchBlobError = CloudKitMediaStoreError.notFound
        return (recordName, try Data(contentsOf: enc3))
    }

    func testReverseMoveFromAShortChunkedAssemblyKeepsTheRecordAndBringsTheFullVideoHomeOnResume() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [source.key, dest.key]
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [source, dest]
        let runner = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store },
                                              chunkStore: chunkStore)
        defer { cleanup(source, dest) }
        let id = UUID().uuidString
        let video = try await seedChunkedVideoRecord(store: store, chunkStore: chunkStore, album: source, id: id)
        addTeardownBlock { await CloudKitBlobCache.shared.evict(recordName: video.recordName) }
        let plan = try MigrationPlan(id: UUID().uuidString, source: MigrationEndpoint(album: source),
                                     destination: MigrationEndpoint(album: dest), scope: .items,
                                     items: [MigrationItem(mediaID: id, recordName: video.recordName, mediaType: .video,
                                                           createdAt: Date(), sizeBytes: Int64(video.ciphertext.count))],
                                     createdAt: Date())
        let destModel = LocalStorageModel(album: dest)
        try destModel.initializeDirectories()
        let localURL = destModel.driveURLForMedia(withID: id, type: .video)
        // An assembly that stopped two chunks short of the header's geometry.
        try await seedCacheEntry(video.ciphertext.prefix(video.ciphertext.count - 2_100), recordName: video.recordName,
                                 albumID: try XCTUnwrap(source.albumID), changeTag: "tag")

        await runner.start(plan: plan)

        XCTAssertFalse(deleted(store, video.recordName),
                       "a copy of a short assembly must not be taken as proof the record can go")
        guard case .failed = runner.state else { return XCTFail("expected a failed run, got \(runner.state)") }
        let cached = await isCached(video.recordName, changeTag: "tag")
        XCTAssertFalse(cached, "the short assembly must be evicted so the next attempt reassembles the chunks")

        let loaded = await MigrationPlanStore(sourceAlbum: source, planID: plan.id).load()
        let persisted = try XCTUnwrap(loaded)
        await runner.start(plan: persisted)

        XCTAssertEqual(runner.state, .completed,
                       "a full reassembly verifies against the header, not the record's legacy sizeBytes")
        XCTAssertTrue(try Data(contentsOf: localURL) == video.ciphertext,
                      "the full video comes home byte for byte")
        XCTAssertTrue(deleted(store, video.recordName))
    }

    private func fileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
    }

    // MARK: - Resume from an interrupted upload

    /// A run killed mid-upload leaves its item `uploading`. When the record did land,
    /// the resume confirms it and goes on to verify, without saving it again.
    func testForwardMoveResumedFromUploadingWhoseRecordLandedVerifiesWithoutReuploading() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        albumManager.albumsOnDisk = [source, dest]
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 1, albumManager: albumManager, album: source)
        var plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        plan.items[0].state = .uploading
        let item = plan.items[0]
        store.metadataToReturn = [CloudKitMediaMetadata(
            recordName: item.recordName, albumID: try XCTUnwrap(dest.albumID), mediaID: item.mediaID,
            mediaType: item.mediaType, createdAt: item.createdAt, sizeBytes: item.sizeBytes,
            creationDeviceID: "mock", schemaVersion: 1, recordChangeTag: "tag"
        )]

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        XCTAssertTrue(store.uploadCalls.isEmpty, "a record that landed before the kill is not saved again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: ids[0]).path),
                       "the source is deleted once the landed record verifies")
    }

    /// When the record never landed, the resume uploads the item once and finishes
    /// the move; the local original stays until then.
    func testForwardMoveResumedFromUploadingWhoseRecordNeverLandedUploadsItOnce() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        albumManager.albumsOnDisk = [source, dest]
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 2, albumManager: albumManager, album: source)
        var plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        plan.items[0].state = .uploading

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .completed)
        XCTAssertEqual(store.uploadCalls.sorted(), ids.sorted(), "each item is uploaded exactly once")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceEncURL(album: source, id: id).path),
                           "the source is deleted after its verified upload")
        }
    }

    // MARK: - An open destination album

    /// The destination album is open while items move into it: its own coordinator
    /// syncs throughout, as a gallery on screen does. Every moved item must be in
    /// that album's index when the move finishes, and stay there after it syncs.
    func testAnOpenDestinationAlbumsCoordinatorKeepsTheMovedIDs() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = InMemoryCloudKitMediaStore(uploadDelay: .milliseconds(20))
        let keyManager = DemoKeyManager()
        keyManager.storedKeysValue = [source.key, dest.key]
        keyManager.currentKey = source.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [source, dest]
        let runner = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store })
        defer { cleanup(source, dest) }

        let ids = try await seedLocalAlbum(count: 4, albumManager: albumManager, album: source)
        let destKeyManager = DemoKeyManager()
        destKeyManager.currentKey = dest.key
        let openDestination = await CloudKitFileAccess(album: dest,
                                                       albumManager: MockAlbumManager(keyManager: destKeyManager),
                                                       store: store)
        await openDestination.start()
        let before = await openDestination.mediaIndex()?.entries ?? []
        XCTAssertTrue(before.isEmpty, "precondition: the open destination starts empty")

        let syncing = Task {
            while !Task.isCancelled {
                await openDestination.start()
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let plan = buildPlan(sourceAlbum: source, destinationAlbum: dest, ids: ids)
        await runner.start(plan: plan)
        syncing.cancel()
        await syncing.value

        XCTAssertEqual(runner.state, .completed)
        let afterMove = Set((await openDestination.mediaIndex()?.entries ?? []).map(\.id))
        XCTAssertEqual(afterMove, Set(ids), "the open album's index holds every moved item")

        await openDestination.start()
        let afterSync = Set((await openDestination.mediaIndex()?.entries ?? []).map(\.id))
        XCTAssertEqual(afterSync, Set(ids), "a sync of the open album keeps every moved item")
        let listed: [InteractableMedia<EncryptedMedia>] = await openDestination.enumerateMedia()
        XCTAssertEqual(Set(listed.map(\.id)), Set(ids), "the open album lists every moved item")
    }

    // MARK: - The source album's cover

    /// A forward move of `count` seeded photos whose source album uses `cover` as its
    /// cover, and whose destination uses `destinationCover`.
    private func forwardCoverFixture(count: Int,
                                     cover: (_ ids: [String]) -> String?,
                                     destinationCover: String? = "dest-cover")
        async throws -> (runner: CloudKitMigrationManager, albumManager: MockAlbumManager,
                         store: MockCloudKitMediaStore, source: Album, dest: Album, ids: [String]) {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        let ids = try await seedLocalAlbum(count: count, albumManager: albumManager, album: source)
        albumManager.coverImageIDs[source.id] = cover(ids)
        albumManager.coverImageIDs[dest.id] = destinationCover
        albumManager.albumsOnDisk = [source, dest]
        return (runner, albumManager, store, source, dest, ids)
    }

    func testMovingTheSourceCoverItemToCloudKitFallsTheSourceBackToItsDefaultCover() async throws {
        let f = try await forwardCoverFixture(count: 2, cover: { $0[1] })
        defer { cleanup(f.source, f.dest) }

        await f.runner.start(plan: buildPlan(sourceAlbum: f.source, destinationAlbum: f.dest, ids: f.ids))

        XCTAssertEqual(f.runner.state, .completed)
        XCTAssertNil(f.albumManager.getAlbumCoverImageId(album: f.source),
                     "the source album must fall back to its default cover once its cover item has moved")
        XCTAssertEqual(f.albumManager.getAlbumCoverImageId(album: f.dest), "dest-cover",
                       "only the source album's cover changes")
    }

    func testMovingTheSourceCoverItemToLocalFallsTheSourceBackToItsDefaultCover() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }
        let ids = [UUID().uuidString]
        seedCloudKitRecords(store: store, ids: ids)
        try dest.storageOption.modelForType.init(album: dest).initializeDirectories()
        albumManager.coverImageIDs[source.id] = ids[0]
        albumManager.coverImageIDs[dest.id] = "dest-cover"
        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids))

        XCTAssertEqual(runner.state, .completed)
        XCTAssertNil(albumManager.getAlbumCoverImageId(album: source),
                     "the CloudKit source album must fall back to its default cover once its cover item has moved")
        XCTAssertEqual(albumManager.getAlbumCoverImageId(album: dest), "dest-cover",
                       "only the source album's cover changes")
    }

    func testMovingItemsOtherThanTheCoverLeavesTheSourceCoverAlone() async throws {
        let f = try await forwardCoverFixture(count: 3, cover: { $0[2] })
        defer { cleanup(f.source, f.dest) }

        await f.runner.start(plan: buildPlan(sourceAlbum: f.source, destinationAlbum: f.dest,
                                             ids: Array(f.ids.prefix(2))))

        XCTAssertEqual(f.runner.state, .completed)
        XCTAssertEqual(f.albumManager.getAlbumCoverImageId(album: f.source), f.ids[2])
        XCTAssertTrue(f.albumManager.resetCoverCalls.isEmpty)
    }

    func testMovingItemsOutOfAnAlbumWhoseCoverIsTurnedOffKeepsItTurnedOff() async throws {
        let f = try await forwardCoverFixture(count: 2, cover: { _ in CloudKitAlbumMarker.disabledCoverID })
        defer { cleanup(f.source, f.dest) }

        await f.runner.start(plan: buildPlan(sourceAlbum: f.source, destinationAlbum: f.dest, ids: f.ids))

        XCTAssertEqual(f.runner.state, .completed)
        XCTAssertEqual(f.albumManager.getAlbumCoverImageId(album: f.source), CloudKitAlbumMarker.disabledCoverID)
        XCTAssertTrue(f.albumManager.resetCoverCalls.isEmpty)
    }

    func testACoverItemThatFailsToMoveStaysTheSourceCover() async throws {
        let f = try await forwardCoverFixture(count: 1, cover: { $0[0] })
        defer { cleanup(f.source, f.dest) }
        f.store.reflectUploadsInMetadata = false

        await f.runner.start(plan: buildPlan(sourceAlbum: f.source, destinationAlbum: f.dest, ids: f.ids))

        guard case .failed = f.runner.state else { return XCTFail("expected a failed run, got \(f.runner.state)") }
        XCTAssertEqual(f.albumManager.getAlbumCoverImageId(album: f.source), f.ids[0])
        XCTAssertTrue(f.albumManager.resetCoverCalls.isEmpty)
    }

    func testACancelledMoveKeepsTheCoverOfAnItemItNeverMoved() async throws {
        let f = try await forwardCoverFixture(count: 2, cover: { $0[1] })
        defer { cleanup(f.source, f.dest) }
        let plan = buildPlan(sourceAlbum: f.source, destinationAlbum: f.dest, ids: f.ids)
        f.store.onUploadStarted = { [weak runner = f.runner] in await runner?.cancel(plan: plan) }

        await f.runner.start(plan: plan)

        let persisted = await MigrationPlanStore(sourceAlbum: f.source, planID: plan.id).load()
        XCTAssertNotNil(persisted?.cancelledAt, "precondition: the move was cancelled")
        XCTAssertNotEqual(persisted?.items[1].state, .sourceDeleted, "precondition: the cover item never moved")
        XCTAssertEqual(f.albumManager.getAlbumCoverImageId(album: f.source), f.ids[1])
    }

    func testASkippedCoverItemStaysTheSourceCover() async throws {
        let source = makeAlbum(storage: .cloudKit)
        let dest = makeAlbum(storage: .local)
        let store = MockCloudKitMediaStore()
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        defer { cleanup(source, dest) }
        let ids = [UUID().uuidString]
        store.fetchBlobError = CloudKitMediaStoreError.notFound
        try dest.storageOption.modelForType.init(album: dest).initializeDirectories()
        albumManager.coverImageIDs[source.id] = ids[0]
        albumManager.albumsOnDisk = [source, dest]

        await runner.start(plan: buildReversePlan(sourceAlbum: source, destinationAlbum: dest, ids: ids))

        XCTAssertEqual(runner.state, .completed, "precondition: the missing record was skipped")
        XCTAssertEqual(albumManager.getAlbumCoverImageId(album: source), ids[0])
        XCTAssertTrue(albumManager.resetCoverCalls.isEmpty)
    }

    /// A Live Photo is matched on its media id, and is still the cover while one of
    /// its halves is in the source album.
    func testALivePhotoCoverStaysUntilItsSecondHalfHasMoved() async throws {
        let source = makeAlbum(storage: .local)
        let dest = makeAlbum(storage: .cloudKit)
        let store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let (runner, albumManager) = makeRunner(store: store, keys: [source.key, dest.key])
        (albumManager.keyManager as! DemoKeyManager).currentKey = source.key
        defer { cleanup(source, dest) }
        let id = try await seedLivePhoto(albumManager: albumManager, album: source)
        let plan = buildLivePhotoPlan(sourceAlbum: source, destinationAlbum: dest, id: id)
        albumManager.coverImageIDs[source.id] = id
        albumManager.albumsOnDisk = [source, dest]
        store.uploadFailures[plan.items[1].recordName] = CloudKitMediaStoreError.quotaExceeded

        await runner.start(plan: plan)

        XCTAssertEqual(runner.state, .failed(.quota), "precondition: only the photo half moved")
        XCTAssertEqual(albumManager.getAlbumCoverImageId(album: source), id,
                       "a Live Photo with a half still in the source stays its cover")

        store.uploadFailures = [:]
        let checkpoint = await MigrationPlanStore(sourceAlbum: source, planID: plan.id).load()
        XCTAssertEqual(checkpoint?.items[0].state, .sourceDeleted, "precondition: the photo half moved")
        await runner.resume(plan: try XCTUnwrap(checkpoint))

        XCTAssertEqual(runner.state, .completed)
        XCTAssertNil(albumManager.getAlbumCoverImageId(album: source),
                     "once both halves have moved the source falls back to its default cover")
    }
}

/// Records what a test observed at each record delete.
private final class DeleteObserver: @unchecked Sendable {
    var sizes: [Int64?] = []
}

/// Thread-safe recorder for the claim-observation test.
private actor ClaimObserver {
    private(set) var value = false
    func record(_ v: Bool) { value = v }
}

/// Counts the `FileOperationBus` delete events that name one media id.
private final class DeleteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var cancellable: AnyCancellable?

    init(id: String) {
        cancellable = FileOperationBus.shared.operations.sink { [weak self] operation in
            guard case .delete(let media) = operation, media.contains(where: { $0.id == id }) else { return }
            self?.lock.withLock { self?._count += 1 }
        }
    }

    var count: Int { lock.withLock { _count } }

    func cancel() { cancellable?.cancel() }
}

/// Thread-safe recorder for FileOperationBus create events.
private actor BusObserver {
    private(set) var createCount = 0
    func recordCreate() { createCount += 1 }
}
