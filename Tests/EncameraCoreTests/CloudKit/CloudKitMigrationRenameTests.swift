//
//  CloudKitMigrationRenameTests.swift
//  EncameraCoreTests
//
//  Renaming a local album carries its unfinished moves across the rename. Plans live
//  under the source album's id, and a local album's id is its name, so a rename moves
//  the album's own plans to the new id and rewrites every endpoint that names it. A
//  rename is refused while a move is running on the album.
//

import XCTest
import UIKit
@testable import EncameraCore

@MainActor
final class CloudKitMigrationRenameTests: XCTestCase {

    private var albumManager: AlbumManager!
    private var store: MockCloudKitMediaStore!
    private var createdAlbums: [Album] = []

    override func setUp() async throws {
        try await super.setUp()
        let key = PrivateKey(name: "rename-\(UUID().uuidString.prefix(6))",
                             keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) },
                             creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        let boundStore = store!
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in boundStore }
        let priorToggle = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        addTeardownBlock {
            CloudKitStoreProvider.makeStore = priorMakeStore
            FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: priorToggle)
        }
    }

    override func tearDown() async throws {
        for album in createdAlbums {
            try? FileManager.default.removeItem(at: album.storageURL)
            if let albumID = album.albumID {
                try? CloudKitAlbumMarker.remove(albumID: albumID)
            }
        }
        createdAlbums = []
        try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL())
        try? MediaIndexStore.clearAllIndexes()
        albumManager = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeEngine() -> CloudKitMigrationManager {
        let boundStore = store!
        return CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in boundStore })
    }

    private func createAlbum(_ prefix: String, storage: StorageType) throws -> Album {
        let album = try albumManager.create(name: "\(prefix)-\(UUID().uuidString)", storageOption: storage)
        createdAlbums.append(album)
        return album
    }

    private func tinyPNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData() ?? Data()
    }

    private func seedPhotos(_ count: Int, into album: Album) async throws -> [String] {
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        var ids: [String] = []
        for _ in 0..<count {
            let id = UUID().uuidString
            let photo = try InteractableMedia(underlyingMedia: [
                CleartextMedia(source: .data(tinyPNG()), mediaType: .photo, id: id)
            ])
            _ = try await backend.save(media: photo, metadata: nil, progress: { _ in })
            ids.append(id)
        }
        return ids
    }

    private func localFileURL(_ album: Album, id: String) -> URL {
        album.storageOption.modelForType.init(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    private func item(_ id: String, sizeBytes: Int64) -> MigrationItem {
        MigrationItem(mediaID: id,
                      recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                      mediaType: .photo,
                      createdAt: Date(),
                      sizeBytes: sizeBytes)
    }

    /// Pauses `engine` as its second upload starts, so the run stops with one item
    /// moved and the rest still to do.
    private func pauseOnSecondUpload(_ engine: CloudKitMigrationManager) {
        let boundStore = store!
        store.onUploadStarted = { [weak engine] in
            if boundStore.uploadCalls.count == 1 { await engine?.pause() }
        }
    }

    // MARK: - Local source renamed

    func testRenamingTheLocalSourceOfAPausedAlbumMoveResumesIntoTheSameCloudKitAlbum() async throws {
        let album = try createAlbum("Before", storage: .local)
        let ids = try await seedPhotos(3, into: album)

        let first = makeEngine()
        pauseOnSecondUpload(first)
        await first.start(album: album)
        store.onUploadStarted = nil

        let loadedPlan = await MigrationPlanStore(album: album).load()
        let heldPlan = try XCTUnwrap(loadedPlan, "precondition: the move is held")
        XCTAssertTrue(heldPlan.hasRemainingWork, "precondition: the move stopped part-way")
        let albumID = try XCTUnwrap(heldPlan.destination.cloudKitAlbumID)
        XCTAssertEqual(Set(store.savedAlbumCalls.map(\.albumID)), [albumID], "precondition: one EncAlbum so far")

        let renamed = try albumManager.renameAlbum(album: album, to: "After-\(UUID().uuidString)")
        createdAlbums.append(renamed)

        let resumer = makeEngine()
        let pending = await resumer.pendingPlans().filter { $0.destination.cloudKitAlbumID == albumID }
        XCTAssertEqual(pending.map(\.source.albumID), [renamed.id], "the plan is found under the new id")
        XCTAssertEqual(pending.first?.source.albumName, renamed.name)
        XCTAssertEqual(pending.first?.destination.albumName, renamed.name)
        XCTAssertFalse(MigrationPlanStore.hasPlans(for: album), "nothing is left under the old id")

        // The banner's Resume path: re-plan the renamed album, then run.
        await resumer.start(album: renamed)

        XCTAssertEqual(resumer.state, .completed)
        XCTAssertEqual(Set(store.savedAlbumCalls.map(\.albumID)), [albumID],
                       "the resume lands in the album the move started, not a second one")
        XCTAssertEqual(Set(store.uploadedItems.map(\.descriptor.albumID)), [albumID])
        XCTAssertEqual(Set(store.uploadedItems.map(\.descriptor.mediaID)), Set(ids), "every item reached CloudKit")
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: album.key), renamed.name)
        let lastRecord = try XCTUnwrap(store.savedAlbumCalls.last)
        XCTAssertEqual(Album.decryptedAlbumName(lastRecord.encName, key: album.key), renamed.name,
                       "the album record carries the new name")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: localFileURL(renamed, id: id).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.storageURL.path), "the local source is drained")
    }

    /// Mid-move the reconciler can adopt the move's `EncAlbum` from the server, so the
    /// destination already has an `album.json` under the old name. Finalize keeps an
    /// existing marker, so the rename must reach it or the album lands under the old name.
    func testRenamingTheLocalSourceOfAPausedAlbumMoveRenamesItsAdoptedCloudKitTwin() async throws {
        let album = try createAlbum("Adopted", storage: .local)
        let ids = try await seedPhotos(3, into: album)

        let first = makeEngine()
        pauseOnSecondUpload(first)
        await first.start(album: album)
        store.onUploadStarted = nil
        let loadedPlan = await MigrationPlanStore(album: album).load()
        let albumID = try XCTUnwrap(loadedPlan?.destination.cloudKitAlbumID, "precondition: the move is held")
        let twin = Album.cloudKitTwin(of: album, albumID: albumID)
        try CloudKitAlbumMarker(album: twin, isHidden: false).write(albumID: albumID)
        createdAlbums.append(twin)

        let renamed = try albumManager.renameAlbum(album: album, to: "Adopted2-\(UUID().uuidString)")
        createdAlbums.append(renamed)

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: album.key), renamed.name,
                       "the adopted twin takes the new name with the rename")
        let pushDeadline = Date().addingTimeInterval(5)
        func pushedRenamedRecord() -> Bool {
            store.savedAlbumCalls.contains {
                $0.albumID == albumID && Album.decryptedAlbumName($0.encName, key: album.key) == renamed.name
            }
        }
        while !pushedRenamedRecord(), Date() < pushDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(pushedRenamedRecord(), "and its record is pushed with it")

        let resumer = makeEngine()
        await resumer.start(album: renamed)

        XCTAssertEqual(resumer.state, .completed)
        XCTAssertEqual(Set(store.uploadedItems.map(\.descriptor.mediaID)), Set(ids))
        let finalMarker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(Album.decryptedAlbumName(finalMarker.encName, key: album.key), renamed.name,
                       "the finished album carries the new name")
        let found = albumManager.fetchAlbumsFromSources(includingHidden: true).filter { $0.albumID == albumID }
        XCTAssertEqual(found.map(\.name), [renamed.name])
        let lastRecord = try XCTUnwrap(store.savedAlbumCalls.last { $0.albumID == albumID })
        XCTAssertEqual(Album.decryptedAlbumName(lastRecord.encName, key: album.key), renamed.name,
                       "the album record carries the new name")
    }

    func testRenamingTheLocalSourceOfAPausedItemMoveResumesIntoTheSameCloudKitAlbum() async throws {
        let destination = try createAlbum("Dest", storage: .cloudKit)
        let source = try createAlbum("Source", storage: .local)
        let ids = try await seedPhotos(3, into: source)
        let items = ids.map { item($0, sizeBytes: localFileURL(source, id: $0).fileSizeBytes() ?? 0) }
        let plan = try MigrationPlan.items(source: source, destination: destination, items: items)
        try await MigrationPlanStore(sourceAlbum: source, planID: plan.id).save(plan)

        let first = makeEngine()
        pauseOnSecondUpload(first)
        await first.start(plan: plan)
        store.onUploadStarted = nil
        let loadedHeld = await MigrationPlanStore(sourceAlbum: source, planID: plan.id).load()
        let held = try XCTUnwrap(loadedHeld)
        XCTAssertTrue(held.hasRemainingWork, "precondition: the move stopped part-way")

        let renamed = try albumManager.renameAlbum(album: source, to: "Renamed-\(UUID().uuidString)")
        createdAlbums.append(renamed)

        let found = await MigrationPlanStore.plans(for: renamed)
        XCTAssertEqual(found.map(\.id), [plan.id], "the plan is found under the new id")
        XCTAssertFalse(MigrationPlanStore.hasPlans(for: source), "nothing is left under the old id")
        let moved = try XCTUnwrap(found.first)
        XCTAssertEqual(moved.source, MigrationEndpoint(album: renamed))
        XCTAssertEqual(moved.destination, plan.destination)
        XCTAssertEqual(moved.items.map(\.state), held.items.map(\.state), "the items keep their progress")

        let resumer = makeEngine()
        let resumed = await resumer.start(plan: moved)
        XCTAssertTrue(resumed)

        XCTAssertEqual(resumer.state, .completed)
        XCTAssertEqual(Set(store.uploadedItems.map(\.descriptor.albumID)), [destination.albumID!])
        XCTAssertEqual(Set(store.uploadedItems.map(\.descriptor.mediaID)), Set(ids))
        XCTAssertEqual(Set(store.savedAlbumCalls.map(\.albumID)), [destination.albumID!], "one EncAlbum")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(atPath: localFileURL(renamed, id: id).path))
        }
    }

    // MARK: - Local destination renamed

    func testRenamingTheLocalDestinationOfAMoveBackKeepsItResumable() async throws {
        let source = try createAlbum("Cloud", storage: .cloudKit)
        let destination = try createAlbum("Home", storage: .local)
        let ids = [UUID().uuidString, UUID().uuidString]
        store.metadataToReturn = ids.map { id in
            CloudKitMediaMetadata(recordName: CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                                  albumID: source.albumID!, mediaID: id, mediaType: .photo, createdAt: Date(),
                                  sizeBytes: 10, creationDeviceID: "mock", schemaVersion: 1, recordChangeTag: "tag")
        }
        store.blobContents = Data(repeating: 0xAA, count: 10)
        let plan = try MigrationPlan.items(source: source, destination: destination,
                                           items: ids.map { item($0, sizeBytes: 10) })
        try await MigrationPlanStore(sourceAlbum: source, planID: plan.id).save(plan)

        let renamed = try albumManager.renameAlbum(album: destination, to: "Moved-\(UUID().uuidString)")
        createdAlbums.append(renamed)

        let sourcePlans = await MigrationPlanStore.plans(for: source)
        let rewritten = try XCTUnwrap(sourcePlans.first { $0.id == plan.id })
        XCTAssertEqual(rewritten.destination, MigrationEndpoint(album: renamed))
        XCTAssertEqual(rewritten.source, plan.source)
        let engine = makeEngine()
        let albums = engine.albums(for: rewritten)
        XCTAssertEqual(albums?.destination.id, renamed.id, "the plan's destination resolves after the rename")

        let started = await engine.start(plan: rewritten)
        XCTAssertTrue(started)

        XCTAssertEqual(engine.state, .completed)
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: localFileURL(renamed, id: id).path),
                          "the item lands in the renamed album")
        }
        XCTAssertEqual(Set(store.deleteCalls), Set(plan.items.map(\.recordName)))
    }

    // MARK: - Refused while running

    func testRenamingAnAlbumWhileItsMoveIsRunningIsRefused() async throws {
        let album = try createAlbum("Busy", storage: .local)
        _ = try await seedPhotos(2, into: album)
        let manager = albumManager!
        let outcome = RenameOutcome()
        store.onUploadStarted = { @MainActor in
            guard !outcome.attempted else { return }
            outcome.attempted = true
            do {
                _ = try manager.renameAlbum(album: album, to: "Elsewhere-\(UUID().uuidString)")
            } catch {
                outcome.error = error
            }
        }

        let engine = makeEngine()
        await engine.start(album: album)

        XCTAssertTrue(outcome.attempted, "precondition: the rename was tried mid-run")
        XCTAssertEqual(outcome.error as? AlbumError, .moveInProgress)
        XCTAssertEqual(engine.state, .completed, "the running move is unaffected")
    }

    func testRenamingAnAlbumWithNoRunningMoveIsAllowed() throws {
        let album = try createAlbum("Idle", storage: .local)
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: album.id))
        let renamed = try albumManager.renameAlbum(album: album, to: "Idle2-\(UUID().uuidString)")
        createdAlbums.append(renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.storageURL.path))
    }
}

@MainActor
private final class RenameOutcome {
    var attempted = false
    var error: Error?
}
