//
//  AlbumManagerMigrationGuardTests.swift
//  EncameraCoreTests
//
//  `AlbumManager.delete(album:)` refuses an album a storage move still names. A
//  move to CloudKit lands every item in the destination album's record before the
//  source copy goes, and an album record's delete cascades to every media record
//  pointing at it, so deleting either side mid-move would lose what has moved.
//

import XCTest
@testable import EncameraCore

final class AlbumManagerMigrationGuardTests: XCTestCase {

    private let key = PrivateKey(name: "guard", keyBytes: Array(repeating: 0x5A, count: 32),
                                 creationDate: Date(timeIntervalSince1970: 0))
    private var store: MockCloudKitMediaStore!
    private var previousMakeStore: (@Sendable (String) -> CloudKitMediaStoring)!
    private var cleanups: [() async -> Void] = []

    override func setUp() async throws {
        try await super.setUp()
        let store = MockCloudKitMediaStore()
        self.store = store
        previousMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
    }

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
        CloudKitStoreProvider.makeStore = previousMakeStore
        try await super.tearDown()
    }

    private func makeManager() -> AlbumManager {
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        return AlbumManager(keyManager: keyManager, syncedDataStore: nil)
    }

    /// A local album with its directory on disk.
    private func makeLocalAlbum() throws -> Album {
        let album = Album(name: "guard-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
        try LocalStorageModel(album: album).initializeDirectories()
        cleanups.append { try? FileManager.default.removeItem(at: album.storageURL) }
        return album
    }

    // MARK: - Tests

    func testDeleteRefusesTheDestinationOfAPendingPlan() async throws {
        let source = try makeLocalAlbum()
        let albumID = UUID().uuidString
        let destination = Album.cloudKitTwin(of: source, albumID: albumID)
        try CloudKitAlbumMarker(album: destination, isHidden: false).write(albumID: albumID)
        cleanups.append { try? CloudKitAlbumMarker.remove(albumID: albumID) }
        // A paused move: the plan is on disk, no run is driving it.
        let planStore = MigrationPlanStore(album: source)
        try await planStore.save(try MigrationPlan.album(source, items: [], cloudKitAlbumID: albumID))
        cleanups.append { await planStore.delete() }
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: destination.id), .destination(.toCloudKit, isRunning: false),
                       "precondition: the plan names the CloudKit album as its destination")
        let manager = makeManager()

        XCTAssertThrowsError(try manager.delete(album: destination)) { error in
            guard case AlbumError.moveInProgress = error else {
                return XCTFail("expected AlbumError.moveInProgress, got \(error)")
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty, "no album record is deleted")
        XCTAssertFalse(CloudKitAlbumDeleteQueue().pending().contains(albumID), "no delete is queued for later either")
        XCTAssertTrue(CloudKitAlbumMarker.exists(albumID: albumID), "the album stays on this device")
        let checkpoint = await planStore.load()
        XCTAssertNotNil(checkpoint, "the move's checkpoint is untouched")
    }

    func testDeleteRefusesTheSourceOfAnActiveRun() throws {
        let source = try makeLocalAlbum()
        let destination = Album.cloudKitTwin(of: source, albumID: UUID().uuidString)
        MigrationRunRoles.shared.begin(source: source.id, destination: destination.id, direction: .toCloudKit)
        defer { MigrationRunRoles.shared.end(source: source.id, destination: destination.id) }
        let manager = makeManager()

        XCTAssertThrowsError(try manager.delete(album: source)) { error in
            guard case AlbumError.moveInProgress = error else {
                return XCTFail("expected AlbumError.moveInProgress, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.storageURL.path),
                      "the source album's files are left where they are")
        XCTAssertTrue(store.deletedAlbumCalls.isEmpty)
    }

    /// Without a move the delete goes ahead as before.
    func testDeleteOfAnAlbumNoMoveNamesStillDeletes() throws {
        let album = try makeLocalAlbum()
        let manager = makeManager()

        try manager.delete(album: album)

        XCTAssertFalse(FileManager.default.fileExists(atPath: album.storageURL.path))
    }

    /// A paused move is not cancelled: launch resumes it, so it still blocks the delete.
    func testDeleteStillRefusesAPausedMove() async throws {
        let source = try makeLocalAlbum()
        let planStore = MigrationPlanStore(album: source)
        try await planStore.save(try MigrationPlan.album(source, items: [], cloudKitAlbumID: UUID().uuidString))
        cleanups.append { await planStore.delete() }

        XCTAssertThrowsError(try makeManager().delete(album: source)) { error in
            guard case AlbumError.moveInProgress = error else {
                return XCTFail("expected AlbumError.moveInProgress, got \(error)")
            }
        }
    }

    /// Cancelling a move to iCloud rolls it back and deletes its plan, so the
    /// album can be deleted without resuming the move.
    @MainActor
    func testDeleteAfterCancelledMoveToCloudKitDeletesWithoutResuming() async throws {
        let source = try makeLocalAlbum()
        let planStore = MigrationPlanStore(album: source)
        try await planStore.save(try MigrationPlan.album(source, items: [], cloudKitAlbumID: UUID().uuidString,
                                                         cloudKitAlbumCreatedByMove: true))
        cleanups.append { await planStore.delete() }
        let manager = makeManager()
        let migration = CloudKitMigrationManager(albumManager: manager, storeFactory: { [store] _ in store! })

        await migration.cancel(album: source)
        try manager.delete(album: source)

        let checkpoint = await planStore.load()
        XCTAssertNil(checkpoint, "the cancel rolled the move back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.storageURL.path), "the album is deleted")
    }

    /// Cancelling a move back to this device rolls it back too, and the iCloud
    /// album it came from can then be deleted.
    @MainActor
    func testDeleteAfterCancelledMoveToLocalDeletesWithoutResuming() async throws {
        let albumID = UUID().uuidString
        let cloudAlbum = Album(name: "guard-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                               key: key, albumID: albumID)
        try CloudKitAlbumMarker(album: cloudAlbum, isHidden: false).write(albumID: albumID)
        cleanups.append { try? CloudKitAlbumMarker.remove(albumID: albumID) }
        let twin = Album.localTwin(of: cloudAlbum)
        try LocalStorageModel(album: twin).initializeDirectories()
        cleanups.append { try? FileManager.default.removeItem(at: twin.storageURL) }
        let planStore = MigrationPlanStore(album: cloudAlbum)
        try await planStore.save(try MigrationPlan.album(cloudAlbum, items: []))
        cleanups.append { await planStore.delete() }
        let manager = makeManager()
        let migration = CloudKitMigrationManager(albumManager: manager, storeFactory: { [store] _ in store! })

        await migration.cancel(album: cloudAlbum)
        try manager.delete(album: cloudAlbum)

        let checkpoint = await planStore.load()
        XCTAssertNil(checkpoint, "the cancel rolled the move back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: twin.storageURL.path), "the local copies went with it")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.deletedAlbumCalls, [albumID], "the iCloud album is deleted")
    }
}
