//
//  PartlyMigratedAlbumWriteTests.swift
//  EncameraCoreTests
//
//  Writes to a CloudKit album whose media is partly still in its linked iCloud
//  Drive folder.
//
//  A user delete of an item: a component on iCloud Drive has no record, so its
//  file goes from the folder in every form, with its index component, size and
//  preview, and the media leaves the album's migration plan, so neither the
//  folder scan nor the blob migration brings it back. A component in CloudKit
//  goes through the record delete as before.
//
//  Album-level writes: a rename, hide or cover change touches `album.json` and
//  the album record only, never the folder. Deleting the album removes its
//  records, the `EncAlbum`, the folder with its marker file and the plan, after
//  the blob migration pass in flight ends, and none of it comes back. New media
//  goes to CloudKit and never into the folder.
//
//  An edit of an item still on iCloud Drive is saved to CloudKit and its file
//  leaves the folder and the migration plan. A move of one uploads it from
//  the folder into a CloudKit album, or copies its ciphertext into a local one,
//  and takes it out of the source album. An item that lands while the edit or
//  move waits for the pass in flight is edited or moved as a CloudKit item.
//
//  The iCloud Drive container is a scratch directory holding real encrypted
//  media, prepared by the real album step against the real `AlbumManager`. The
//  CloudKit store, iCloud Drive's metadata and its downloads are fakes.
//

import XCTest
@testable import EncameraCore

@MainActor
final class PartlyMigratedAlbumWriteTests: XCTestCase {

    private var containerRoot: URL!
    private var scratch: URL!
    private var key: PrivateKey!
    private var albumManager: AlbumManager!
    private var store: MockCloudKitMediaStore!
    private var materializer: FakeICloudDriveMaterializer!
    private var blobCache: CloudKitBlobCache!
    private var folderContents: FakeFolderContents!
    private var folderWatches: ICloudDriveFolderWatches!
    private var changeSources: [FakeFolderChangeSource] = []
    private var albumFinish: ICloudDriveAlbumFinish!
    private var deletedAlbumsSuite: String!
    private var albumDeletion: ICloudDriveAlbumDeletion!
    private var previousMakeStore: (@Sendable (String) -> CloudKitMediaStoring)!
    private var previousCloudKitStorage = false
    private var touchedAlbumIDs: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        containerRoot = base.appendingPathComponent("partly-migrated-\(UUID().uuidString)", isDirectory: true)
        scratch = base.appendingPathComponent("partly-migrated-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot

        key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        materializer = FakeICloudDriveMaterializer()
        blobCache = CloudKitBlobCache(baseDir: scratch.appendingPathComponent("blob-cache", isDirectory: true))
        folderContents = FakeFolderContents()
        folderContents.metadata = []
        folderWatches = ICloudDriveFolderWatches()
        changeSources = []
        albumFinish = ICloudDriveAlbumFinish(albumManager: albumManager, folderContents: folderContents,
                                             folderWatches: folderWatches,
                                             markerConflictVersions: { _ in [] })
        deletedAlbumsSuite = makeIsolatedSuiteName()
        albumDeletion = makeAlbumDeletion()
        albumManager.iCloudDriveAlbumDeletion = albumDeletion
        let store = self.store!
        previousMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        CloudKitSyncCoordinator.resetShared()
        previousCloudKitStorage = FeatureToggle.isEnabled(feature: .cloudKitStorage)
    }

    override func tearDownWithError() throws {
        for albumID in touchedAlbumIDs {
            ICloudDriveBlobMigration.requestStop(albumID: albumID)
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        }
        touchedAlbumIDs = []
        CloudKitStoreProvider.makeStore = previousMakeStore
        CloudKitSyncCoordinator.resetShared()
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: previousCloudKitStorage)
        UserDefaults().removePersistentDomain(forName: deletedAlbumsSuite)
        iCloudStorageModel.testContainerRootOverride = nil
        ICloudPlaceholderName.testEvictedURLs = nil
        try? FileManager.default.removeItem(at: containerRoot)
        try? FileManager.default.removeItem(at: scratch)
        try? MediaIndexStore.clearAllIndexes()
        albumFinish = nil
        changeSources = []
        albumManager = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private struct NotPrepared: Error {}

    private struct Prepared {
        let albumID: String
        let folder: URL
        let album: Album
        let mediaIDs: [String]
        let cloudKitAlbum: Album
    }

    /// An iCloud Drive album holding `count` real encrypted photos, run through
    /// the album step: flipped to its CloudKit album, indexed at `.iCloudDrive`,
    /// planned and watched.
    private func prepareAlbum(count: Int) async throws -> Prepared {
        let album = Album(name: "trip-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: key)
        let model = iCloudStorageModel(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        var ids: [String] = []
        for _ in 0..<count {
            let id = UUID().uuidString
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
                ]),
                metadata: nil, progress: { _ in })
            ids.append(id)
        }
        let outcome = await makeAlbumStep().run(folder: model.baseURL)
        guard case .prepared(let albumID) = outcome else {
            XCTFail("precondition: the album step prepared the album, got \(outcome)")
            throw NotPrepared()
        }
        touchedAlbumIDs.insert(albumID)
        let cloudKitAlbum = try XCTUnwrap(albumManager.cloudKitAlbum(withID: albumID))
        return Prepared(albumID: albumID, folder: model.baseURL, album: album, mediaIDs: ids,
                        cloudKitAlbum: cloudKitAlbum)
    }

    /// The removal of a deleted album's iCloud Drive half, over the deleted album
    /// ids this device keeps. Built again from the same store for a relaunch.
    private func makeAlbumDeletion() -> ICloudDriveAlbumDeletion {
        ICloudDriveAlbumDeletion(deletedAlbums: DeletedCloudKitAlbums(defaults: defaults(forSuite: deletedAlbumsSuite)),
                                 isICloudDriveAvailable: { true },
                                 markerConflictVersions: { _ in [] },
                                 folderContents: ICloudDriveAlbumFolderDiskContents(metadataNames: { _ in nil }),
                                 folderWatches: folderWatches,
                                 albumFolders: { iCloudStorageModel.enumerateAlbumsDirectory() })
    }

    private func makeAlbumStep(albumManager: AlbumManager? = nil,
                               albumDeletion: ICloudDriveAlbumDeletion? = nil,
                               albumFolders: (() -> [URL])? = nil) -> ICloudDriveAlbumMigration {
        let store = self.store!
        let albumManager = albumManager ?? self.albumManager!
        return ICloudDriveAlbumMigration(albumManager: albumManager,
                                         makeStore: { store },
                                         materializer: materializer,
                                         publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()),
                                         deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
                                         conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                           hasICloudDrive: { true }),
                                         conflictVersions: { _ in [] },
                                         flipRegistry: ICloudDriveAlbumFlipRegistry(),
                                         zoneWalkRequests: CloudKitZoneWalkRequests(defaults: makeIsolatedDefaults()),
                                         albumFolders: albumFolders,
                                         startBlobMigration: { _, _ in },
                                         folderWatches: folderWatches,
                                         makeFolderChangeSource: { [unowned self] in
                                             let source = FakeFolderChangeSource()
                                             self.changeSources.append(source)
                                             return source
                                         },
                                         finish: albumFinish,
                                         albumDeletion: albumDeletion ?? self.albumDeletion)
    }

    private func makeLoop() -> ICloudDriveBlobMigration {
        let store = self.store!
        return ICloudDriveBlobMigration(albumManager: albumManager,
                                        makeStore: { store },
                                        materializer: materializer,
                                        makeVerifiedDelete: { ICloudDriveVerifiedDelete(store: $0,
                                                                                        markerConflictVersions: { _ in [] }) },
                                        conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                          hasICloudDrive: { true }),
                                        deviceState: { BlobMigrationDeviceState(isUnlocked: true) },
                                        markerConflictVersions: { _ in [] },
                                        deviceResourceStateObserver: .init(isLowPowerModeEnabled: { false },
                                                                           thermalState: { .nominal },
                                                                           notificationCenter: NotificationCenter()),
                                        blobCache: blobCache,
                                        fileVersions: NoFileVersions(),
                                        finish: albumFinish)
    }

    /// The CloudKit album's file access over the fake store. A pass it starts is
    /// handed to `startingPasses`; with none, it starts nothing.
    private func makeAccess(_ prepared: Prepared,
                            startingPasses: (@MainActor (_ albumID: String) async -> Void)? = nil) async -> CloudKitFileAccess {
        let materializer = self.materializer!
        let albumFinish = self.albumFinish!
        var iCloudDrive = CloudKitICloudDriveFolderAccess(makeMaterializer: { materializer })
        iCloudDrive.markerConflictVersions = { _ in [] }
        iCloudDrive.makeAlbumFinish = { _ in albumFinish }
        iCloudDrive.startMigrationPass = { _, albumID in await startingPasses?(albumID) }
        return await CloudKitFileAccess(album: prepared.cloudKitAlbum, albumManager: albumManager,
                                        store: store, iCloudDrive: iCloudDrive)
    }

    private func makeScanner(_ prepared: Prepared) -> ICloudDriveFolderScanner {
        let folder = prepared.folder
        return ICloudDriveFolderScanner(album: prepared.cloudKitAlbum,
                                        indexStore: albumManager.mediaIndexStore(for: prepared.cloudKitAlbum),
                                        sizeSidecar: albumManager.sizeSidecar(for: prepared.cloudKitAlbum),
                                        store: store,
                                        changeSource: FakeFolderChangeSource(),
                                        isICloudDriveAvailable: { true },
                                        linkedFolder: { _ in folder },
                                        markerConflictVersions: { _ in [] })
    }

    /// The folder's listing on disk and its removal, real, with nothing reported
    /// by iCloud Drive's metadata unless set.
    private final class FakeFolderContents: ICloudDriveAlbumFolderContents, @unchecked Sendable {
        private let lock = NSLock()
        private var reported: [String]?
        private let disk = ICloudDriveAlbumFolderDiskContents(metadataNames: { _ in nil })

        var metadata: [String]? {
            get { lock.withLock { reported } }
            set { lock.withLock { reported = newValue } }
        }

        func fileSystemNames(in folder: URL) -> [String]? { disk.fileSystemNames(in: folder) }
        func metadataNames(in folder: URL) async -> [String]? { metadata }
        func removeFolder(_ folder: URL, ifStillHolding holdsNothingElse: ([String]) -> Bool) throws -> Bool {
            try disk.removeFolder(folder, ifStillHolding: holdsNothingElse)
        }
    }

    /// The folder watch's change notifications, fired by the test.
    private final class FakeFolderChangeSource: ICloudDriveFolderChangeSource {
        private var onChange: (@Sendable () -> Void)?

        nonisolated init() {}

        func start(watching folder: URL, onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func stop() { onChange = nil }
        func fire() { onChange?() }
    }

    private final class NoFileVersions: ICloudDriveFileVersioning, @unchecked Sendable {
        func unresolvedConflictVersionURLs(of url: URL) -> [URL] { [] }
        func resolveConflicts(keepingCurrentVersionOf url: URL) throws {}
    }

    private func recordName(_ mediaID: String, _ type: MediaType = .photo) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: type)
    }

    private func fileURL(_ prepared: Prepared, _ mediaID: String, _ type: MediaType = .photo) -> URL {
        prepared.folder.appendingPathComponent("\(mediaID).\(type.encryptedFileExtension)")
    }

    private func photo(_ prepared: Prepared, _ mediaID: String) throws -> InteractableMedia<EncryptedMedia> {
        try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(fileURL(prepared, mediaID)), mediaType: .photo, id: mediaID)
        ])
    }

    private func previewURL(_ mediaID: String) -> URL {
        CloudKitStorageModel.previewURL(forMediaID: mediaID)
    }

    private func entries(_ prepared: Prepared) async -> [MediaIndexEntry] {
        await albumManager.mediaIndexStore(for: prepared.cloudKitAlbum).reloadFromDisk()?.entries ?? []
    }

    private func entry(_ prepared: Prepared, _ mediaID: String) async -> MediaIndexEntry? {
        await entries(prepared).first { $0.id == mediaID }
    }

    private func planStore(_ prepared: Prepared) -> MigrationPlanStore {
        MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album, cloudKitAlbumID: prepared.albumID)
    }

    private func planMediaIDs(_ prepared: Prepared) async throws -> Set<String> {
        let plan = await planStore(prepared).load()
        return Set(try XCTUnwrap(plan, "the album has a migration plan").items.map(\.mediaID))
    }

    private func existsInAnyForm(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: ICloudPlaceholderName.placeholderURL(forMaterialized: url).path)
    }

    /// Writes a preview for `mediaID`, as reading or saving its media does.
    private func writePreview(_ mediaID: String) throws {
        let url = previewURL(mediaID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preview".utf8).write(to: url)
    }

    private func recordICloudDriveSizes(_ prepared: Prepared) async throws {
        let entries = await entries(prepared)
        var sizes: [String: Int64] = [:]
        for entry in entries where entry.photoLocation == .iCloudDrive {
            sizes[recordName(entry.id)] = Int64(try Data(contentsOf: fileURL(prepared, entry.id)).count)
        }
        try await albumManager.sizeSidecar(for: prepared.cloudKitAlbum)
            .apply(updates: sizes, removals: [], owner: .iCloudDrive, entries: entries)
    }

    // MARK: - Tests

    func testDeletingICloudDriveItemRemovesFilePreviewAndComponent() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let deleted = prepared.mediaIDs[0]
        let evicted = prepared.mediaIDs[1]
        for id in prepared.mediaIDs { try writePreview(id) }
        try await recordICloudDriveSizes(prepared)
        try materializer.evictForTest(fileURL(prepared, evicted), shape: .replacedByPlaceholderBrick)
        let entryBefore = await entry(prepared, deleted)
        XCTAssertEqual(entryBefore?.photoLocation, .iCloudDrive, "precondition: the photo is still on iCloud Drive")
        let access = await makeAccess(prepared)

        try await access.delete(media: [photo(prepared, deleted)])

        XCTAssertFalse(existsInAnyForm(fileURL(prepared, deleted)), "the file is gone from the folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL(deleted).path), "the preview is deleted")
        let entryAfter = await entry(prepared, deleted)
        XCTAssertNil(entryAfter, "the index component is removed")
        let sidecar = albumManager.sizeSidecar(for: prepared.cloudKitAlbum)
        let deletedSize = await sidecar.bytes(forRecordName: recordName(deleted))
        XCTAssertNil(deletedSize, "its size is dropped")
        XCTAssertFalse(store.deleteCalls.contains(recordName(deleted)), "an item with no record deletes no record")
        XCTAssertTrue(existsInAnyForm(fileURL(prepared, evicted)), "the other item's file is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL(evicted).path), "the other item's preview is kept")
        let kept = await entry(prepared, evicted)
        XCTAssertEqual(kept?.photoLocation, .iCloudDrive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.folder.path), "the folder still holds an item")
        let partlyWhileOneLeft = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum,
                                                                                      albumManager: albumManager)
        XCTAssertTrue(partlyWhileOneLeft)

        // An evicted file goes as it is: its placeholder is removed, nothing is downloaded.
        try await access.delete(media: [photo(prepared, evicted)])

        XCTAssertFalse(existsInAnyForm(fileURL(prepared, evicted)), "the evicted item's placeholder is gone")
        XCTAssertEqual(materializer.requestedBatches, [], "deleting an evicted file downloads nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL(evicted).path))
        let remaining = await entries(prepared)
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path),
                       "deleting the last item on iCloud Drive finishes the album and removes its folder")
        let partlyAfterLast = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum,
                                                                                   albumManager: albumManager)
        XCTAssertFalse(partlyAfterLast, "nothing of the album is left on iCloud Drive")
        XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID))
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath)
        XCTAssertFalse(folderWatches.isWatching(albumID: prepared.albumID))
    }

    func testRescanDoesNotResurrectDeletedItem() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let deleted = prepared.mediaIDs[0]
        let kept = prepared.mediaIDs[1]
        let access = await makeAccess(prepared)
        XCTAssertTrue(folderWatches.isWatching(albumID: prepared.albumID), "precondition: the album step watches the folder")

        // A delete that cannot reach the folder removes nothing, rather than an
        // index component whose file a later scan would index again.
        var unreachable = CloudKitICloudDriveFolderAccess(makeMaterializer: { [materializer] in materializer! })
        unreachable.isICloudDriveAvailable = { false }
        let withoutICloudDrive = await CloudKitFileAccess(album: prepared.cloudKitAlbum, albumManager: albumManager,
                                                          store: store, iCloudDrive: unreachable)
        do {
            try await withoutICloudDrive.delete(media: [photo(prepared, deleted)])
            XCTFail("a delete of an item on iCloud Drive without iCloud Drive is refused")
        } catch ICloudDriveItemDeleteError.folderUnavailable(let reason) {
            XCTAssertEqual(reason, .iCloudDriveUnavailable)
        }
        XCTAssertTrue(existsInAnyForm(fileURL(prepared, deleted)))
        let refusedEntry = await entry(prepared, deleted)
        XCTAssertEqual(refusedEntry?.photoLocation, .iCloudDrive)

        try await access.delete(media: [photo(prepared, deleted)])

        let scan = await makeScanner(prepared).scan()
        XCTAssertEqual(scan, .scanned(added: [], removed: []), "a rescan adds nothing back")
        for source in changeSources { source.fire() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterWatch = await entries(prepared).map(\.id)
        XCTAssertEqual(afterWatch, [kept], "the folder watch does not index it again")

        let rerun = await makeAlbumStep().run(folder: prepared.folder)
        XCTAssertEqual(rerun, .prepared(albumID: prepared.albumID))
        let afterRerun = await entries(prepared).map(\.id)
        XCTAssertEqual(afterRerun, [kept], "the album step's parity scan does not index it again")
        let planned = try await planMediaIDs(prepared)
        XCTAssertEqual(planned, [kept], "the album step's merge does not plan it again")
        let listed = await access.enumerate().map(\.id)
        XCTAssertEqual(listed, [kept], "the album does not show it")
    }

    func testDeletingPartlyMovedLivePhotoDeletesRecordAndFile() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let other = prepared.mediaIDs[0]
        let livePhoto = UUID().uuidString
        let photoURL = fileURL(prepared, livePhoto, .photo)
        let videoURL = fileURL(prepared, livePhoto, .video)
        // The photo half reached CloudKit and its file has not been deleted yet;
        // the video half is still only on iCloud Drive.
        try Data("photo ciphertext".utf8).write(to: photoURL)
        try Data("video ciphertext".utf8).write(to: videoURL)
        let date = Date()
        try await albumManager.mediaIndexStore(for: prepared.cloudKitAlbum).upsert([
            MediaIndexEntry(id: livePhoto, hasPhotoComponent: true, hasVideoComponent: true,
                            dateEncrypted: date, dateTaken: date, subtypeRawValue: 0,
                            photoLocation: .cloudKit, videoLocation: .iCloudDrive)
        ])
        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: recordName(livePhoto, .photo), albumID: prepared.albumID,
                                  mediaID: livePhoto, mediaType: .photo, createdAt: date, sizeBytes: 16,
                                  creationDeviceID: "this-device", schemaVersion: 1, recordChangeTag: "tag")
        ]
        let planStore = planStore(prepared)
        let loaded = await planStore.load()
        var plan = try XCTUnwrap(loaded)
        plan.items.append(MigrationItem(mediaID: livePhoto, recordName: recordName(livePhoto, .photo),
                                        mediaType: .photo, createdAt: date, sizeBytes: 16, state: .verified))
        plan.items.append(MigrationItem(mediaID: livePhoto, recordName: recordName(livePhoto, .video),
                                        mediaType: .video, createdAt: date, sizeBytes: 16))
        try await planStore.save(plan)
        try writePreview(livePhoto)
        let access = await makeAccess(prepared)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(photoURL), mediaType: .photo, id: livePhoto),
            EncryptedMedia(source: .url(videoURL), mediaType: .video, id: livePhoto)
        ])

        try await access.delete(media: [media])

        XCTAssertEqual(store.deleteCalls, [recordName(livePhoto, .photo)],
                       "the half in CloudKit has its record deleted, and only that half")
        XCTAssertFalse(existsInAnyForm(videoURL), "the half still on iCloud Drive has its file deleted")
        XCTAssertFalse(existsInAnyForm(photoURL), "the moved half's leftover file is deleted too")
        let liveEntry = await entry(prepared, livePhoto)
        XCTAssertNil(liveEntry, "both components leave the index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL(livePhoto).path), "the shared preview is deleted")
        let planned = try await planMediaIDs(prepared)
        XCTAssertEqual(planned, [other], "neither half stays in the plan")

        let scan = await makeScanner(prepared).scan()
        XCTAssertEqual(scan, .scanned(added: [], removed: []), "a rescan brings neither half back")
    }

    func testDeletedItemIsDroppedFromPlan() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let deleted = prepared.mediaIDs[0]
        let kept = prepared.mediaIDs[1]
        let planStore = planStore(prepared)
        // A copy another writer loaded before the delete: a pass part-way through
        // an item, or the album step merging the folder into the plan it read.
        let loadedBeforeDelete = await planStore.load()
        let staleCopy = try XCTUnwrap(loadedBeforeDelete)
        XCTAssertEqual(Set(staleCopy.items.map(\.mediaID)), Set(prepared.mediaIDs), "precondition: both are planned")
        let access = await makeAccess(prepared)

        try await access.delete(media: [photo(prepared, deleted)])

        let afterDelete = try await planMediaIDs(prepared)
        XCTAssertEqual(afterDelete, [kept], "the deleted item leaves the plan")
        try await planStore.save(staleCopy)
        let afterStaleSave = try await planMediaIDs(prepared)
        XCTAssertEqual(afterStaleSave, [kept], "a save from a copy loaded before the delete does not bring it back")

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("the pass finishes, got \(outcome)") }
        XCTAssertEqual(store.uploadedItems.map(\.mediaID), [kept], "the deleted item is never uploaded")
        XCTAssertEqual(report.deleted, [recordName(kept)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path),
                       "the deleted item does not hold the folder alive")
        let partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertFalse(partly)
    }

    func testEvictedFileIsNotTreatedAsDeleted() async throws {
        let prepared = try await prepareAlbum(count: 3)
        let deletedElsewhere = prepared.mediaIDs[0]
        let evicted = prepared.mediaIDs[1]
        let notYetDownloaded = prepared.mediaIDs[2]
        for id in prepared.mediaIDs { try writePreview(id) }
        // Another device's delete reaches this one as the file leaving the folder.
        try FileManager.default.removeItem(at: fileURL(prepared, deletedElsewhere))
        // One file was evicted in place; the other is known here only as iCloud
        // Drive's placeholder.
        try materializer.evictForTest(fileURL(prepared, evicted), shape: .pathPersists)
        try materializer.evictForTest(fileURL(prepared, notYetDownloaded), shape: .replacedByPlaceholderBrick)

        let scan = await makeScanner(prepared).scan()

        XCTAssertEqual(scan, .scanned(added: [], removed: [recordName(deletedElsewhere)]),
                       "only the file gone in every form, with no record, counts as deleted")
        let remaining = await entries(prepared)
        XCTAssertEqual(Set(remaining.map(\.id)), [evicted, notYetDownloaded])
        XCTAssertTrue(remaining.allSatisfy { $0.photoLocation == .iCloudDrive })
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL(evicted).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL(notYetDownloaded).path))
        XCTAssertEqual(materializer.requestedBatches, [], "nothing is downloaded to decide")
        let planned = try await planMediaIDs(prepared)
        XCTAssertTrue(planned.isSuperset(of: [evicted, notYetDownloaded]), "both stay planned to move")
    }

    func testUploadLandingAfterDeleteIsDeleted() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let mediaID = prepared.mediaIDs[0]
        let name = recordName(mediaID)
        let source = scratch.appendingPathComponent("\(mediaID).upload")
        try FileManager.default.copyItem(at: fileURL(prepared, mediaID), to: source)
        let access = await makeAccess(prepared)
        // A migration upload of the item already in flight when the user deletes it,
        // through a coordinator sharing the file access's delete bookkeeping.
        let uploader = CloudKitSyncCoordinator(store: store, cache: blobCache, albumManager: albumManager,
                                               uploadQueue: CloudKitUploadQueue(baseDir: scratch.appendingPathComponent("uploads")),
                                               deleteQueue: CloudKitMediaDeleteQueue(suiteName: CloudKitFileAccess.testDeleteSuiteName))
        let item = CloudKitMediaUpload(albumID: prepared.albumID, mediaID: mediaID, mediaType: .photo,
                                       createdAt: Date(), sizeBytes: Int64(try Data(contentsOf: source).count),
                                       encryptedFileURL: source, encryptedThumbURL: nil, recordName: name)
        let toDelete = try photo(prepared, mediaID)
        store.onUploadStarted = { try? await access.delete(media: [toDelete]) }

        do {
            _ = try await uploader.upload(item, progress: { _ in })
            XCTFail("an upload that lands after the delete is discarded")
        } catch CloudKitMediaStoreError.cancelled {
        }

        XCTAssertEqual(store.deleteCalls, [name], "the record the upload landed is deleted")
        XCTAssertFalse(existsInAnyForm(fileURL(prepared, mediaID)))
        let left = await entries(prepared)
        XCTAssertEqual(left, [], "the landed upload does not put the item back in the index")
    }

    // MARK: - Album-level writes

    /// Every entry in the folder, with its size, so any write into it shows.
    private func folderSnapshot(_ prepared: Prepared) throws -> [String: Int] {
        var snapshot: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: prepared.folder.path) {
            let url = prepared.folder.appendingPathComponent(name)
            snapshot[name] = (try? Data(contentsOf: url))?.count ?? -1
        }
        return snapshot
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func listedFolderAlbums(_ manager: AlbumManager, _ prepared: Prepared) -> [Album] {
        let path = CloudKitAlbumMarker.iCloudDriveFolderPath(for: prepared.folder)
        return manager.fetchAlbumsFromSources(includingHidden: true).filter { album in
            album.storageOption == .icloud
                && manager.storageModel(for: album).flatMap { CloudKitAlbumMarker.iCloudDriveFolderPath(for: $0.baseURL) } == path
        }
    }

    private func savePhoto(_ access: CloudKitFileAccess) async throws -> InteractableMedia<EncryptedMedia> {
        let saved = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: UUID().uuidString)
        ]), metadata: nil, progress: { _ in })
        await access.drainUploads()
        return try XCTUnwrap(saved)
    }

    func testRenameDuringMigrationChangesRecordAndMarkerOnly() async throws {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        let prepared = try await prepareAlbum(count: 2)
        let folderBefore = try folderSnapshot(prepared)
        let markerFileBefore = try Data(contentsOf: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: prepared.folder))
        let linkBefore = CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath
        XCTAssertNotNil(linkBefore, "precondition: the album links its folder")
        // A blob migration pass is part-way through its first item.
        let gate = AsyncGate()
        store.onUploadStarted = { await gate.enter() }
        let loop = makeLoop()
        let pass = Task { await loop.runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) }
        await gate.waitUntilEntered()

        let newName = "renamed-\(UUID().uuidString)"
        let renamed = try albumManager.renameAlbum(album: prepared.cloudKitAlbum, to: newName)

        XCTAssertEqual(renamed.albumID, prepared.albumID, "the album keeps its id")
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: prepared.albumID))
        XCTAssertEqual(marker.encName, renamed.encryptedPathComponent, "album.json takes the new name")
        XCTAssertEqual(marker.iCloudDriveFolderPath, linkBefore, "album.json still links the same folder")
        try await waitUntil { [store] in store!.savedAlbumCalls.last?.encName == renamed.encryptedPathComponent }
        XCTAssertEqual(store.savedAlbumCalls.last?.albumID, prepared.albumID, "the album record takes the new name")
        XCTAssertEqual(try folderSnapshot(prepared), folderBefore, "the folder keeps its name and contents")
        XCTAssertEqual(try Data(contentsOf: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: prepared.folder)),
                       markerFileBefore, "the folder's marker file is untouched")

        // Another device, which has not adopted the album yet, finds it through
        // the folder's marker and lists it under the new name.
        try CloudKitAlbumMarker.remove(albumID: prepared.albumID)
        let walk = ICloudDriveAlbumFolderWalk(albumManager: albumManager, makeStore: { [store] in store! },
                                              publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()),
                                              deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
                                              conflictVersions: { _ in [] },
                                              flipRegistry: ICloudDriveAlbumFlipRegistry(),
                                              deletedAlbums: DeletedCloudKitAlbums(defaults: makeIsolatedDefaults()))
        let found = await walk.walk(folder: prepared.folder)
        XCTAssertTrue(found.changedAlbumMarker, "the walk adopts the album from the folder's marker")
        let adopted = try XCTUnwrap(albumManager.cloudKitAlbum(withID: prepared.albumID))
        XCTAssertEqual(adopted.name, newName, "the album is found under its new name")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath, linkBefore)
        XCTAssertEqual(listedFolderAlbums(albumManager, prepared), [], "the folder is not listed as an album of its own")

        await gate.release()
        let outcome = await pass.value
        guard case .finished(let report) = outcome else { return XCTFail("the pass goes on, got \(outcome)") }
        XCTAssertEqual(Set(report.deleted), Set(prepared.mediaIDs.map { recordName($0) }),
                       "the rename does not stop the migration")
    }

    func testHideAndCoverDuringMigrationAreAllowed() async throws {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        let prepared = try await prepareAlbum(count: 2)
        let access = await makeAccess(prepared)
        let cover = try await savePhoto(access)
        let folderBefore = try folderSnapshot(prepared)
        let plannedBefore = try await planMediaIDs(prepared)
        let linkBefore = CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath

        albumManager.setIsAlbumHidden(true, album: prepared.cloudKitAlbum)

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.isHidden, true, "album.json is hidden")
        try await waitUntil { [store] in store!.savedAlbumCalls.last?.isHidden == true }
        XCTAssertTrue(albumManager.isAlbumHidden(prepared.cloudKitAlbum))
        XCTAssertFalse(albumManager.fetchAlbumsFromSources(includingHidden: false).contains { $0.albumID == prepared.albumID },
                       "the hidden album leaves the list")
        XCTAssertEqual(listedFolderAlbums(albumManager, prepared), [], "its folder does not show in its place")

        albumManager.setAlbumCoverImage(album: prepared.cloudKitAlbum, image: cover)

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.coverMediaID, cover.id, "album.json has the cover")
        try await waitUntil { [store] in store!.savedAlbumCalls.last?.coverMediaID == cover.id }
        XCTAssertEqual(store.savedAlbumCalls.last?.isHidden, true, "the record keeps the hidden flag")
        XCTAssertEqual(albumManager.getAlbumCoverImageId(album: prepared.cloudKitAlbum), cover.id)
        XCTAssertEqual(try folderSnapshot(prepared), folderBefore, "the folder is untouched")
        let plannedAfter = try await planMediaIDs(prepared)
        XCTAssertEqual(plannedAfter, plannedBefore, "the migration plan is untouched")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath, linkBefore)
        let partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertTrue(partly, "the album is still partly migrated")
    }

    func testDeleteAlbumDuringMigrationRemovesFolderRecordsAndPlan() async throws {
        let prepared = try await prepareAlbum(count: 2)
        for id in prepared.mediaIDs { try writePreview(id) }
        try await recordICloudDriveSizes(prepared)
        XCTAssertTrue(folderWatches.isWatching(albumID: prepared.albumID), "precondition: the folder is watched")
        // A copy of the plan another writer loaded before the delete, as the album step does.
        let loadedBeforeDelete = await planStore(prepared).load()
        let staleCopy = try XCTUnwrap(loadedBeforeDelete)
        // A blob migration pass is part-way through its first item.
        let gate = AsyncGate()
        store.onUploadStarted = { await gate.enter() }
        let loop = makeLoop()
        let pass = Task { await loop.runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) }
        await gate.waitUntilEntered()
        XCTAssertTrue(ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID))

        try albumManager.delete(album: prepared.cloudKitAlbum)

        XCTAssertNil(albumManager.cloudKitAlbum(withID: prepared.albumID), "the album leaves the list at once")
        XCTAssertEqual(listedFolderAlbums(albumManager, prepared), [], "its folder does not show in its place")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.folder.path),
                      "the folder waits for the item in flight")
        XCTAssertEqual(store.deletedAlbumCalls, [], "so does the album record")

        await gate.release()
        let outcome = await pass.value
        guard case .stopped = outcome else { return XCTFail("the pass stops, got \(outcome)") }
        XCTAssertEqual(store.uploadCalls.count, 1, "no item starts after the delete")
        await albumDeletion.waitForRemoval(albumID: prepared.albumID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path),
                       "the folder goes with its files and marker file")
        XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID),
                       "the plan goes, and the item in flight does not write it back")
        try await planStore(prepared).save(staleCopy)
        XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID),
                       "a save from a copy loaded before the delete does not bring it back")
        XCTAssertEqual(store.deletedAlbumCalls, [prepared.albumID], "the album record goes, its media records with it")
        XCTAssertFalse(CloudKitAlbumMarker.exists(albumID: prepared.albumID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaIndexStore.indexURL(for: prepared.cloudKitAlbum).path),
                       "the index goes, and the item in flight does not write it back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AlbumSizeSidecar.sidecarURL(for: prepared.cloudKitAlbum).path))
        for id in prepared.mediaIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL(id).path), "the previews go")
        }
        XCTAssertFalse(folderWatches.isWatching(albumID: prepared.albumID), "the folder watch is stopped")
        XCTAssertFalse(ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID))
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
        let partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertFalse(partly)
    }

    func testDeleteAlbumWithUnreachableFolderDeletesNothing() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: prepared.folder)
        let marker = try Data(contentsOf: markerURL)
        // Without its marker file nothing says the folder is the album's.
        try FileManager.default.removeItem(at: markerURL)

        XCTAssertThrowsError(try albumManager.delete(album: prepared.cloudKitAlbum)) { error in
            XCTAssertEqual(error as? ICloudDriveItemDeleteError, .folderUnavailable(.markerAbsent))
        }

        XCTAssertTrue(CloudKitAlbumMarker.exists(albumID: prepared.albumID), "the album stays")
        XCTAssertTrue(existsInAnyForm(fileURL(prepared, prepared.mediaIDs[0])), "its only copy on iCloud Drive stays")
        XCTAssertTrue(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID))
        XCTAssertFalse(albumDeletion.deletedAlbums.contains(prepared.albumID))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.deletedAlbumCalls, [])

        try marker.write(to: markerURL)
        try albumManager.delete(album: prepared.cloudKitAlbum)
        await albumDeletion.waitForRemoval(albumID: prepared.albumID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path), "once reachable, it goes")
    }

    func testEraseDiscardEmptiesTheIndexAfterTheLinkedFolderIsGone() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let access = await makeAccess(prepared)
        // Erase All Data removes every linked folder before the album's own step.
        _ = await albumDeletion.removeEveryLinkedFolder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path), "precondition: the folder is gone")
        do {
            try await access.deleteAllMedia()
            XCTFail("precondition: a per-item delete of iCloud Drive items without their folder is refused")
        } catch ICloudDriveItemDeleteError.folderUnavailable {}

        try await access.discardAllMediaForErase()

        let remaining = await access.enumerate()
        XCTAssertEqual(remaining.map(\.id), [], "the album lists no media")
        let stored = await entries(prepared)
        XCTAssertEqual(stored, [], "the stored index is empty")
        XCTAssertEqual(store.deleteCalls, [], "the zone delete already took the records; none is deleted per item")
    }

    func testDeletedPartlyMigratedAlbumDoesNotReturnOnRelaunch() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let markerFile = try Data(contentsOf: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: prepared.folder))
        let leftover = try Data(contentsOf: fileURL(prepared, prepared.mediaIDs[0]))
        try albumManager.delete(album: prepared.cloudKitAlbum)
        await albumDeletion.waitForRemoval(albumID: prepared.albumID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path), "precondition: the folder is gone")
        let savesAtDelete = store.savedAlbumCalls.count

        // A relaunch: a new manager over what is on disk.
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let relaunched = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        let relaunchedDeletion = makeAlbumDeletion()
        relaunched.iCloudDriveAlbumDeletion = relaunchedDeletion
        XCTAssertFalse(relaunched.fetchAlbumsFromSources(includingHidden: true).contains { $0.albumID == prepared.albumID },
                       "the album is not listed after a relaunch")

        // The folder comes back as another device still syncing it: its marker
        // names the deleted album, and it holds an item.
        try FileManager.default.createDirectory(at: prepared.folder, withIntermediateDirectories: true)
        try markerFile.write(to: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: prepared.folder))
        try leftover.write(to: fileURL(prepared, prepared.mediaIDs[0]))

        XCTAssertEqual(listedFolderAlbums(relaunched, prepared), [], "the remnant is not listed as a plain iCloud Drive album")
        let walk = ICloudDriveAlbumFolderWalk(albumManager: relaunched, makeStore: { [store] in store! },
                                              publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()),
                                              deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
                                              conflictVersions: { _ in [] },
                                              flipRegistry: ICloudDriveAlbumFlipRegistry(),
                                              deletedAlbums: relaunchedDeletion.deletedAlbums)
        let walked = await walk.walk(folder: prepared.folder)
        XCTAssertEqual(walked.adoptionState, .deletePending(albumID: prepared.albumID), "the walk does not adopt it again")
        XCTAssertFalse(walked.changedAlbumMarker)
        XCTAssertFalse(CloudKitAlbumMarker.exists(albumID: prepared.albumID))

        let step = makeAlbumStep(albumManager: relaunched, albumDeletion: relaunchedDeletion,
                                 albumFolders: { [prepared] in [prepared.folder] })
        _ = await step.runEveryFolder()

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.folder.path), "the album step removes the remnant")
        XCTAssertFalse(CloudKitAlbumMarker.exists(albumID: prepared.albumID), "the album step does not bring the album back")
        XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID), "nor its plan")
        XCTAssertEqual(store.savedAlbumCalls.count, savesAtDelete, "nor its record")
        let record = try await store.fetchAlbum(albumID: prepared.albumID)
        XCTAssertNil(record, "the record stays deleted")
        XCTAssertFalse(relaunched.fetchAlbumsFromSources(includingHidden: true).contains {
            $0.albumID == prepared.albumID || $0.storageOption == .icloud
        })
    }

    func testCaptureNeverWritesToICloudDriveFolder() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let folderBefore = try folderSnapshot(prepared)
        let plannedBefore = try await planMediaIDs(prepared)
        let access = await makeAccess(prepared)

        let captured = try await savePhoto(access)
        let imported = try await savePhoto(access)

        XCTAssertEqual(try folderSnapshot(prepared), folderBefore, "nothing new is written to the folder")
        XCTAssertEqual(Set(store.uploadCalls), [captured.id, imported.id], "new media goes to CloudKit")
        for id in [captured.id, imported.id] {
            let saved = await entry(prepared, id)
            XCTAssertEqual(saved?.photoLocation, .cloudKit)
        }
        let plannedAfter = try await planMediaIDs(prepared)
        XCTAssertEqual(plannedAfter, plannedBefore, "new media is never planned to move")
        let scan = await makeScanner(prepared).scan()
        XCTAssertEqual(scan, .scanned(added: [], removed: []), "the folder scan finds nothing new")
    }

    // MARK: - Edits of an item still on iCloud Drive

    /// Saves `cleartext` as the new content of `mediaID`, as an edit does.
    private func saveEdit(_ access: CloudKitFileAccess, _ mediaID: String, _ cleartext: Data) async throws {
        _ = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(cleartext), mediaType: .photo, id: mediaID)
        ]), metadata: nil, progress: { _ in })
    }

    /// The cleartext of `mediaID` as the album reads it.
    private func cleartext(_ access: CloudKitFileAccess, _ prepared: Prepared, _ mediaID: String) async throws -> Data? {
        let opened = try await access.loadMedia(media: try photo(prepared, mediaID), progress: { _ in })
        guard case .data(let data) = opened.underlyingMedia.first?.source else { return nil }
        return data
    }

    func testEditOfICloudDriveItemSavesToCloudKitAndRetiresItsFile() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let edited = prepared.mediaIDs[0]
        let kept = prepared.mediaIDs[1]
        try await recordICloudDriveSizes(prepared)
        var passesStarted: [String] = []
        let access = await makeAccess(prepared, startingPasses: { passesStarted.append($0) })
        let rotated = TestImageData.png(width: 40, height: 20)

        try await saveEdit(access, edited, rotated)
        await access.drainUploads()

        XCTAssertEqual(store.uploadCalls, [edited], "the edit is saved to CloudKit")
        let landed = await entry(prepared, edited)
        XCTAssertEqual(landed?.photoLocation, .cloudKit, "the item is in CloudKit now")
        XCTAssertFalse(existsInAnyForm(fileURL(prepared, edited)), "its iCloud Drive file is gone")
        let planned = try await planMediaIDs(prepared)
        XCTAssertEqual(planned, [kept], "nothing migrates the old file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL(edited).path), "the preview stays")
        let reread = try await cleartext(access, prepared, edited)
        XCTAssertEqual(reread, rotated)
        XCTAssertEqual(passesStarted, [prepared.albumID], "the migration goes on after the edit")

        _ = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        XCTAssertEqual(store.uploadCalls.filter { $0 == edited }.count, 1, "the old file is never uploaded over the edit")
        let reopened = try await cleartext(access, prepared, edited)
        XCTAssertEqual(reopened, rotated)
    }

    func testEditWhileItemUploadsWaitsAndEditsItsRecord() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let edited = prepared.mediaIDs[0]
        let access = await makeAccess(prepared)
        let gate = AsyncGate()
        store.onUploadStarted = { await gate.enter() }
        let pass = Task { await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) }
        await gate.waitUntilEntered()
        let original = try Data(contentsOf: fileURL(prepared, edited))
        let rotated = TestImageData.png(width: 40, height: 20)

        let edit = Task { try await saveEdit(access, edited, rotated) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try Data(contentsOf: fileURL(prepared, edited)), original,
                       "the edit does not write under the upload in flight")
        store.onUploadStarted = nil
        await gate.release()
        _ = await pass.value
        try await edit.value
        await access.drainUploads()

        let landed = await entry(prepared, edited)
        XCTAssertEqual(landed?.photoLocation, .cloudKit, "the item landed first")
        XCTAssertEqual(store.uploadCalls.filter { $0 == edited }.count, 2, "the migration's upload, then the edit's")
        let reread = try await cleartext(access, prepared, edited)
        XCTAssertEqual(reread, rotated, "the record holds the edit")
    }

    // MARK: - Moves of an item still on iCloud Drive

    /// The move of items still on iCloud Drive over the fake store. A pass it
    /// starts is handed to `startingPasses`; with none, it starts nothing.
    private func makeMove(startingPasses: (@MainActor (_ albumID: String) async -> Void)? = nil) -> ICloudDriveItemMove {
        let store = self.store!
        return ICloudDriveItemMove(albumManager: albumManager,
                                   makeStore: { store },
                                   materializer: materializer,
                                   isICloudDriveAvailable: { true },
                                   markerConflictVersions: { _ in [] },
                                   startMigrationPass: { albumID in await startingPasses?(albumID) },
                                   blobCache: blobCache)
    }

    private func makeCloudKitAlbum() throws -> Album {
        let album = try albumManager.create(name: "target-\(UUID().uuidString)", storageOption: .cloudKit)
        if let albumID = album.albumID { touchedAlbumIDs.insert(albumID) }
        return album
    }

    private func planItem(_ prepared: Prepared, _ mediaID: String) async throws -> MigrationItem {
        let loaded = await planStore(prepared).load()
        let plan = try XCTUnwrap(loaded)
        return try XCTUnwrap(plan.items.first { $0.mediaID == mediaID })
    }

    /// Defers `mediaID`'s move as the blob migration does: back to `pending`
    /// with `reason`, its file and component left on iCloud Drive.
    private func markDeferred(_ prepared: Prepared, _ mediaID: String, _ reason: MigrationDeferralReason) async throws {
        let store = planStore(prepared)
        let loaded = await store.load()
        var plan = try XCTUnwrap(loaded)
        for index in plan.items.indices where plan.items[index].mediaID == mediaID {
            plan.items[index].state = .pending
            plan.items[index].deferralReason = reason
        }
        try await store.save(plan)
    }

    /// Asserts nothing of `mediaID` is left in the album it moved out of.
    private func assertLeftAlbum(_ prepared: Prepared, _ mediaID: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let leftBehind = await entry(prepared, mediaID)
        XCTAssertNil(leftBehind, "it leaves the album's index", file: file, line: line)
        let planned = try await planMediaIDs(prepared)
        XCTAssertFalse(planned.contains(mediaID), "and its migration plan", file: file, line: line)
        XCTAssertFalse(existsInAnyForm(fileURL(prepared, mediaID)), "and its iCloud Drive folder", file: file, line: line)
        let size = await albumManager.sizeSidecar(for: prepared.cloudKitAlbum).bytes(forRecordName: recordName(mediaID))
        XCTAssertNil(size, "and its sizes", file: file, line: line)
    }

    func testMoveOfICloudDriveItemToCloudKitAlbumUploadsItIntoTarget() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let moved = prepared.mediaIDs[0]
        let kept = prepared.mediaIDs[1]
        try await recordICloudDriveSizes(prepared)
        try writePreview(moved)
        let target = try makeCloudKitAlbum()
        var passesStarted: [String] = []

        let outcome = try await makeMove(startingPasses: { passesStarted.append($0) })
            .move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target)

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(store.uploadCalls, [moved], "uploaded once")
        XCTAssertEqual(store.reassignCalls.count, 0, "straight into the target album, as a move to CloudKit from this device")
        let owner = try await store.confirmAlbum(recordName: recordName(moved))
        XCTAssertEqual(owner, target.albumID)
        let targetEntries = await albumManager.mediaIndexStore(for: target).current()?.entries ?? []
        XCTAssertEqual(targetEntries.map(\.id), [moved])
        XCTAssertEqual(targetEntries.first?.photoLocation, .cloudKit)
        try await assertLeftAlbum(prepared, moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL(moved).path), "the preview stays for the target album")
        let planned = try await planMediaIDs(prepared)
        XCTAssertEqual(planned, [kept], "the rest of the album still migrates")
        XCTAssertEqual(passesStarted, [prepared.albumID], "and its migration goes on")
    }

    func testMoveOfICloudDriveItemToLocalAlbumMovesItsFile() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let moved = prepared.mediaIDs[0]
        try await recordICloudDriveSizes(prepared)
        try writePreview(moved)
        let original = try Data(contentsOf: fileURL(prepared, moved))
        let target = try albumManager.create(name: "local-\(UUID().uuidString)", storageOption: .local)

        let outcome = try await makeMove().move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target)

        XCTAssertEqual(outcome, .moved)
        XCTAssertEqual(store.uploadCalls, [], "nothing goes through CloudKit")
        let local = LocalStorageModel(album: target).driveURLForMedia(withID: moved, type: .photo)
        XCTAssertEqual(try Data(contentsOf: local), original, "the ciphertext is in the local album")
        let targetEntries = await albumManager.mediaIndexStore(for: target).current()?.entries ?? []
        XCTAssertEqual(targetEntries.map(\.id), [moved])
        try await assertLeftAlbum(prepared, moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL(moved).path), "the preview stays for the target album")
    }

    func testMoveOfEvictedItemDownloadsItFirst() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let moved = prepared.mediaIDs[0]
        let original = try Data(contentsOf: fileURL(prepared, moved))
        try materializer.evictForTest(fileURL(prepared, moved), shape: .replacedByPlaceholderBrick)
        let target = try albumManager.create(name: "local-\(UUID().uuidString)", storageOption: .local)

        let outcome = try await makeMove().move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target)

        XCTAssertEqual(outcome, .moved)
        let local = LocalStorageModel(album: target).driveURLForMedia(withID: moved, type: .photo)
        XCTAssertEqual(try Data(contentsOf: local), original)
        try await assertLeftAlbum(prepared, moved)
    }

    func testMoveOfDeferredItemMovesIt() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let moved = prepared.mediaIDs[0]
        try await markDeferred(prepared, moved, .neverDownloads)
        let target = try makeCloudKitAlbum()

        let outcome = try await makeMove().move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target)

        XCTAssertEqual(outcome, .moved, "a deferred item moves when the user moves it")
        let owner = try await store.confirmAlbum(recordName: recordName(moved))
        XCTAssertEqual(owner, target.albumID)
        try await assertLeftAlbum(prepared, moved)
    }

    func testMoveOfItemWhoseRecordIsAnotherAlbumsKeepsIt() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let moved = prepared.mediaIDs[0]
        try await markDeferred(prepared, moved, .recordInAnotherAlbum)
        store.confirmAlbumOverride[recordName(moved)] = .success("other-album")
        let target = try makeCloudKitAlbum()

        do {
            _ = try await makeMove().move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target)
            XCTFail("the move fails")
        } catch {}

        XCTAssertEqual(store.uploadCalls, [], "nothing is saved over the other album's record")
        let stillHere = await entry(prepared, moved)
        XCTAssertEqual(stillHere?.photoLocation, .iCloudDrive, "the item stays where it was")
        XCTAssertTrue(existsInAnyForm(fileURL(prepared, moved)))
        let item = try await planItem(prepared, moved)
        XCTAssertEqual(item.deferralReason, .recordInAnotherAlbum)
        let targetEntries = await albumManager.mediaIndexStore(for: target).current()?.entries ?? []
        XCTAssertEqual(targetEntries, [])
    }

    func testMoveRefusedForUnverifiedFolderChangesNothing() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let moved = prepared.mediaIDs[0]
        let target = try makeCloudKitAlbum()
        // Without its marker file nothing says the folder is the album's.
        try FileManager.default.removeItem(at: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: prepared.folder))

        do {
            _ = try await makeMove().move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target)
            XCTFail("the move is refused")
        } catch {
            XCTAssertEqual(error as? ICloudDriveItemDeleteError, .folderUnavailable(.markerAbsent))
        }

        XCTAssertEqual(store.uploadCalls, [])
        let stillHere = await entry(prepared, moved)
        XCTAssertEqual(stillHere?.photoLocation, .iCloudDrive)
        XCTAssertTrue(existsInAnyForm(fileURL(prepared, moved)))
        let planned = try await planMediaIDs(prepared)
        XCTAssertTrue(planned.contains(moved))
    }

    func testMoveOfItemThatLandsMeanwhileIsLeftToTheCloudKitMove() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let moved = prepared.mediaIDs[0]
        let target = try makeCloudKitAlbum()
        let gate = AsyncGate()
        store.onUploadStarted = { await gate.enter() }
        let pass = Task { await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) }
        await gate.waitUntilEntered()

        let move = Task { try await makeMove().move(photo(prepared, moved), from: prepared.cloudKitAlbum, to: target) }
        try await Task.sleep(nanoseconds: 100_000_000)
        store.onUploadStarted = nil
        await gate.release()
        _ = await pass.value
        let outcome = try await move.value

        XCTAssertEqual(outcome, .inCloudKit, "the upload in flight landed it, so it moves as a CloudKit item")
        XCTAssertEqual(store.uploadCalls, [moved], "uploaded once, into its own album")
        let stillHere = await entry(prepared, moved)
        XCTAssertEqual(stillHere?.photoLocation, .cloudKit)
    }
}
