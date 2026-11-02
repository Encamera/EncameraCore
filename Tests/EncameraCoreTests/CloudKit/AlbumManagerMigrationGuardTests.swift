//
//  AlbumManagerMigrationGuardTests.swift
//  EncameraCoreTests
//
//  `AlbumManager.delete(album:)` refuses an album a storage move still names. A
//  move to CloudKit lands every item in the destination album's record before the
//  source copy goes, and an album record's delete cascades to every media record
//  pointing at it, so deleting either side mid-move would lose what has moved.
//  The one exception is a paused move into a CloudKit album from the iCloud Drive
//  folder it links: that album is one album partly in two places, and its delete
//  takes the plan with it.
//
//  A CloudKit album partly still in its linked iCloud Drive folder does not move
//  back to this device until the blob migration has finished it: the move back
//  copies records only. The partly migrated album is real encrypted media in a
//  scratch iCloud Drive container, prepared by the real album step and finished
//  by the real blob migration against the real `AlbumManager`.
//

import XCTest
@testable import EncameraCore

final class AlbumManagerMigrationGuardTests: XCTestCase {

    private let key = PrivateKey(keyBytes: Array(repeating: 0x5A, count: 32),
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

    func testLocalToCloudKitMoveStillRefusesDelete() async throws {
        // A paused move of a local album into a CloudKit album.
        let source = try makeLocalAlbum()
        let albumID = UUID().uuidString
        let destination = Album.cloudKitTwin(of: source, albumID: albumID)
        try CloudKitAlbumMarker(album: destination, isHidden: false).write(albumID: albumID)
        cleanups.append { try? CloudKitAlbumMarker.remove(albumID: albumID) }
        let planStore = MigrationPlanStore(album: source)
        try await planStore.save(try MigrationPlan.album(source, items: [], cloudKitAlbumID: albumID))
        cleanups.append { await planStore.delete() }

        // A paused move of an iCloud Drive folder into the CloudKit album that links it.
        let containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guard-container-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot
        cleanups.append {
            iCloudStorageModel.testContainerRootOverride = nil
            try? FileManager.default.removeItem(at: containerRoot)
        }
        let folderAlbum = Album(name: "guard-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: key)
        let folder = iCloudStorageModel(album: folderAlbum).baseURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linkedID = UUID().uuidString
        let linked = Album.cloudKitTwin(of: folderAlbum, albumID: linkedID)
        var linkedMarker = CloudKitAlbumMarker(album: linked, isHidden: false)
        XCTAssertTrue(linkedMarker.linkICloudDriveFolder(folder))
        try linkedMarker.write(albumID: linkedID)
        cleanups.append { try? CloudKitAlbumMarker.remove(albumID: linkedID) }
        let linkedPlanStore = MigrationPlanStore(album: folderAlbum)
        try await linkedPlanStore.save(try MigrationPlan.album(folderAlbum, items: [], cloudKitAlbumID: linkedID))
        cleanups.append { await linkedPlanStore.delete() }
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: linked.id), .destination(.toCloudKit, isRunning: false),
                       "precondition: both plans name a CloudKit album as their destination")

        let manager = makeManager()
        manager.iCloudDriveAlbumDeletion = ICloudDriveAlbumDeletion(
            deletedAlbums: DeletedCloudKitAlbums(defaults: makeIsolatedDefaults()),
            isICloudDriveAvailable: { true }, markerConflictVersions: { _ in [] },
            folderContents: ICloudDriveAlbumFolderDiskContents(metadataNames: { _ in nil }),
            folderWatches: ICloudDriveFolderWatches(), albumFolders: { [] })

        for album in [destination, source] {
            XCTAssertThrowsError(try manager.delete(album: album)) { error in
                guard case AlbumError.moveInProgress = error else {
                    return XCTFail("expected AlbumError.moveInProgress, got \(error)")
                }
            }
        }
        XCTAssertTrue(CloudKitAlbumMarker.exists(albumID: albumID), "the local move's destination stays")
        let checkpoint = await planStore.load()
        XCTAssertNotNil(checkpoint, "the local move's checkpoint is untouched")

        try manager.delete(album: linked)

        await manager.iCloudDriveAlbumDeletion.waitForRemoval(albumID: linkedID)
        XCTAssertFalse(CloudKitAlbumMarker.exists(albumID: linkedID), "the linked album is deleted")
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: linked.id), .none, "its paused move's plan goes with it")
        XCTAssertEqual(store.deletedAlbumCalls, [linkedID])
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: destination.id), .destination(.toCloudKit, isRunning: false),
                       "the local move's plan is untouched")
    }

    // MARK: - Move back to this device

    private struct PartlyMigrated {
        let albumID: String
        let folder: URL
        let cloudKitAlbum: Album
        let albumManager: AlbumManager
        let albumFinish: ICloudDriveAlbumFinish
    }

    private struct NotPrepared: Error {}

    /// The folder watch's change notifications, which nothing fires here.
    private final class SilentFolderChangeSource: ICloudDriveFolderChangeSource {
        nonisolated init() {}
        func start(watching folder: URL, onChange: @escaping @Sendable () -> Void) {}
        func stop() {}
    }

    private final class NoFileVersions: ICloudDriveFileVersioning, @unchecked Sendable {
        func unresolvedConflictVersionURLs(of url: URL) -> [URL] { [] }
        func resolveConflicts(keepingCurrentVersionOf url: URL) throws {}
    }

    /// An iCloud Drive album holding `count` real encrypted photos, run through the
    /// album step: flipped to its CloudKit album, linked, planned and indexed at
    /// `.iCloudDrive`, with no item moved yet.
    @MainActor
    private func preparePartlyMigratedAlbum(count: Int) async throws -> PartlyMigrated {
        let containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guard-move-back-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot
        cleanups.append {
            iCloudStorageModel.testContainerRootOverride = nil
            try? FileManager.default.removeItem(at: containerRoot)
            try? MediaIndexStore.clearAllIndexes()
        }
        store.reflectUploadsInMetadata = true
        let albumManager = makeManager()
        let folderWatches = ICloudDriveFolderWatches()
        let albumFinish = ICloudDriveAlbumFinish(
            albumManager: albumManager,
            folderContents: ICloudDriveAlbumFolderDiskContents(metadataNames: { _ in [] }),
            folderWatches: folderWatches,
            markerConflictVersions: { _ in [] })

        let album = Album(name: "guard-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: key)
        let model = iCloudStorageModel(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        for _ in 0..<count {
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: UUID().uuidString)
                ]),
                metadata: nil, progress: { _ in })
        }

        let store = self.store!
        let albumStep = ICloudDriveAlbumMigration(
            albumManager: albumManager,
            makeStore: { store },
            materializer: FakeICloudDriveMaterializer(),
            publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()),
            deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
            conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true }, hasICloudDrive: { true }),
            conflictVersions: { _ in [] },
            flipRegistry: ICloudDriveAlbumFlipRegistry(),
            zoneWalkRequests: CloudKitZoneWalkRequests(defaults: makeIsolatedDefaults()),
            startBlobMigration: { _, _ in },
            folderWatches: folderWatches,
            makeFolderChangeSource: { SilentFolderChangeSource() },
            finish: albumFinish)
        guard case .prepared(let albumID) = await albumStep.run(folder: model.baseURL) else {
            XCTFail("precondition: the album step prepared the album")
            throw NotPrepared()
        }
        cleanups.append {
            await MainActor.run { ICloudDriveBlobMigration.requestStop(albumID: albumID) }
            await folderWatches.stop(albumID: albumID)
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        let cloudKitAlbum = try XCTUnwrap(albumManager.cloudKitAlbum(withID: albumID))
        cleanups.append {
            try? FileManager.default.removeItem(at: LocalStorageModel(album: Album.localTwin(of: cloudKitAlbum)).baseURL)
            try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: cloudKitAlbum))
        }
        return PartlyMigrated(albumID: albumID, folder: model.baseURL, cloudKitAlbum: cloudKitAlbum,
                              albumManager: albumManager, albumFinish: albumFinish)
    }

    /// Runs the album's blob migration pass, which moves every item into CloudKit
    /// and finishes the album through `ICloudDriveAlbumFinish`.
    @MainActor
    private func runBlobMigration(_ prepared: PartlyMigrated) async throws {
        let store = self.store!
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guard-blob-cache-\(UUID().uuidString)", isDirectory: true)
        cleanups.append { try? FileManager.default.removeItem(at: scratch) }
        let loop = ICloudDriveBlobMigration(
            albumManager: prepared.albumManager,
            makeStore: { store },
            materializer: FakeICloudDriveMaterializer(),
            makeVerifiedDelete: { ICloudDriveVerifiedDelete(store: $0,
                                                            markerConflictVersions: { _ in [] }) },
            conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true }, hasICloudDrive: { true }),
            markerConflictVersions: { _ in [] },
            deviceResourceStateObserver: .init(isLowPowerModeEnabled: { false }, thermalState: { .nominal },
                                               notificationCenter: NotificationCenter()),
            blobCache: CloudKitBlobCache(baseDir: scratch),
            fileVersions: NoFileVersions(),
            finish: prepared.albumFinish)
        let outcome = await loop.runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        guard case .finished = outcome else {
            return XCTFail("expected the pass to finish, got \(outcome)")
        }
    }

    private func iCloudDriveComponentCount(_ prepared: PartlyMigrated) async -> Int {
        let entries = await prepared.albumManager.mediaIndexStore(for: prepared.cloudKitAlbum).reloadFromDisk()?.entries ?? []
        return entries.filter { $0.photoLocation == .iCloudDrive }.count
    }

    @MainActor
    func testMoveToLocalRefusedWhileICloudDriveComponentsRemain() async throws {
        let prepared = try await preparePartlyMigratedAlbum(count: 2)
        let onICloudDrive = await iCloudDriveComponentCount(prepared)
        XCTAssertEqual(onICloudDrive, 2, "precondition: both items are still on iCloud Drive")
        let migration = CloudKitMigrationManager(albumManager: prepared.albumManager,
                                                 storeFactory: { [store] _ in store! })
        let callsBefore = store.callOrder.count

        let started = await migration.start(plan: try MigrationPlan.album(prepared.cloudKitAlbum, items: []))

        XCTAssertFalse(started, "the move back is refused")
        XCTAssertEqual(migration.state, .idle, "the refusal makes no state transition")
        XCTAssertEqual(store.callOrder.count, callsBefore, "nothing reaches CloudKit")
        let checkpoint = await MigrationPlanStore(album: prepared.cloudKitAlbum).load()
        XCTAssertNil(checkpoint, "no plan is written")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LocalStorageModel(album: Album.localTwin(of: prepared.cloudKitAlbum)).baseURL.path),
                       "no local twin is created")
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: prepared.cloudKitAlbum.id))
        let stillOnICloudDrive = await iCloudDriveComponentCount(prepared)
        XCTAssertEqual(stillOnICloudDrive, 2, "the album is left as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.folder.path), "its folder is untouched")
    }

    @MainActor
    func testMoveToLocalAllowedAfterAlbumIsDone() async throws {
        let prepared = try await preparePartlyMigratedAlbum(count: 2)
        let completed = expectation(forNotification: ICloudDriveAlbumFinish.didComplete, object: nil) { note in
            note.userInfo?["albumID"] as? String == prepared.albumID
        }

        try await runBlobMigration(prepared)

        XCTAssertEqual(prepared.albumFinish.outcomes[prepared.albumID], .removed,
                       "precondition: the finish removed the album's folder")
        await fulfillment(of: [completed], timeout: 1)
        let partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum,
                                                                        albumManager: prepared.albumManager)
        XCTAssertFalse(partly, "precondition: the album is done")
        let migration = CloudKitMigrationManager(albumManager: prepared.albumManager,
                                                 storeFactory: { [store] _ in store! })

        let started = await migration.start(plan: try MigrationPlan.album(prepared.cloudKitAlbum, items: []))

        XCTAssertTrue(started, "the move back runs")
        XCTAssertEqual(migration.state, .completed)
        let local = Album.localTwin(of: prepared.cloudKitAlbum)
        let moved = try FileManager.default.contentsOfDirectory(atPath: LocalStorageModel(album: local).baseURL.path)
            .filter { $0.hasSuffix(MediaType.photo.encryptedFileExtension) }
        XCTAssertEqual(moved.count, 2, "both items are on this device")
    }
}
