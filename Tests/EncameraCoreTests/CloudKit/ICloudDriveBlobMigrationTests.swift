//
//  ICloudDriveBlobMigrationTests.swift
//  EncameraCoreTests
//
//  The per-item loop that moves a prepared iCloud Drive album's media into
//  CloudKit: each item's file is deleted through the verified delete right after
//  its record verifies, never before and never for a record that does not verify.
//
//  The iCloud Drive container is a scratch directory holding real encrypted
//  media, prepared by the real album step against the real `AlbumManager`. The
//  CloudKit store and the iCloud download observation are fakes.
//

import CloudKit
import XCTest
@testable import EncameraCore

@MainActor
final class ICloudDriveBlobMigrationTests: XCTestCase {

    private var containerRoot: URL!
    private var scratch: URL!
    private var key: PrivateKey!
    private var albumManager: AlbumManager!
    private var store: MockCloudKitMediaStore!
    private var materializer: FakeICloudDriveMaterializer!
    private var spy: VerifiedDeleteSpy!
    private var touchedAlbumIDs: Set<String> = []
    private var deviceResourceState: FakeDeviceResourceState!
    private var blobCache: CloudKitBlobCache!
    private var cloudKitStorageWasEnabled = false
    private var folderContents: FakeFolderContents!
    private var folderWatches: ICloudDriveFolderWatches!
    private var changeSources: [FakeFolderChangeSource] = []
    private var albumFinish: ICloudDriveAlbumFinish!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        containerRoot = base.appendingPathComponent("icloud-blob-migration-\(UUID().uuidString)", isDirectory: true)
        scratch = base.appendingPathComponent("icloud-blob-migration-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot

        key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        materializer = FakeICloudDriveMaterializer()
        spy = VerifiedDeleteSpy()
        deviceResourceState = FakeDeviceResourceState()
        blobCache = CloudKitBlobCache(baseDir: scratch.appendingPathComponent("blob-cache", isDirectory: true))
        cloudKitStorageWasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        folderContents = FakeFolderContents()
        folderWatches = ICloudDriveFolderWatches()
        changeSources = []
        albumFinish = ICloudDriveAlbumFinish(albumManager: albumManager, folderContents: folderContents,
                                             folderWatches: folderWatches,
                                             markerConflictVersions: { _ in [] })
    }

    override func tearDownWithError() throws {
        for albumID in touchedAlbumIDs {
            ICloudDriveBlobMigration.requestStop(albumID: albumID)
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        }
        touchedAlbumIDs = []
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: cloudKitStorageWasEnabled)
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

    /// Records every verified delete call and what the store had seen by then,
    /// then hands the call to the real verified delete.
    private final class VerifiedDeleteSpy: ICloudDriveComponentDeleting, @unchecked Sendable {
        struct Call {
            let recordName: String
            let uploadsSoFar: [String]
            let storeCallsSoFar: [MockCloudKitMediaStore.Call]
        }

        var inner: ICloudDriveComponentDeleting?
        var store: MockCloudKitMediaStore?
        private(set) var calls: [Call] = []

        func delete(recordName: String, albumID: String, folder: URL) async -> ICloudDriveVerifiedDeleteResult {
            calls.append(Call(recordName: recordName,
                              uploadsSoFar: store?.uploadedItems.map(\.recordName) ?? [],
                              storeCallsSoFar: store?.callOrder ?? []))
            guard let inner else { return .skipped(.recordMissing) }
            return await inner.delete(recordName: recordName, albumID: albumID, folder: folder)
        }
    }

    private struct NotPrepared: Error {}

    private struct Prepared {
        let albumID: String
        let folder: URL
        let album: Album
        let mediaIDs: [String]
        var cloudKitAlbum: Album
    }

    /// An iCloud Drive album holding `count` real encrypted photos, plus whatever
    /// `seed` writes into its folder, run through the album step.
    private func prepareAlbum(count: Int = 2,
                              store: CloudKitMediaStoring? = nil,
                              seed: ((Album, URL) async throws -> Void)? = nil) async throws -> Prepared {
        let (album, folder, ids) = try await makeICloudDriveAlbum(count: count, seed: seed)
        let outcome = await makeAlbumStep(store: store).run(folder: folder)
        guard case .prepared(let albumID) = outcome else {
            XCTFail("precondition: the album step prepared the album, got \(outcome)")
            throw NotPrepared()
        }
        touchedAlbumIDs.insert(albumID)
        let cloudKitAlbum = try XCTUnwrap(albumManager.cloudKitAlbum(withID: albumID))
        return Prepared(albumID: albumID, folder: folder, album: album, mediaIDs: ids,
                        cloudKitAlbum: cloudKitAlbum)
    }

    /// The album step over the fake store, starting `startBlobMigration` for every
    /// album it prepares.
    private func makeAlbumStep(store: CloudKitMediaStoring? = nil,
                               startBlobMigration: @escaping @MainActor (String, URL) async -> Void = { _, _ in },
                               albumFolders: (() -> [URL])? = nil)
        -> ICloudDriveAlbumMigration {
        let store: CloudKitMediaStoring = store ?? self.store!
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
                                         startBlobMigration: startBlobMigration,
                                         folderWatches: folderWatches,
                                         makeFolderChangeSource: { [unowned self] in
                                             let source = FakeFolderChangeSource()
                                             self.changeSources.append(source)
                                             return source
                                         },
                                         finish: albumFinish)
    }

    /// An iCloud Drive album folder holding `count` real encrypted photos, plus
    /// whatever `seed` writes into it, not yet run through the album step.
    private func makeICloudDriveAlbum(count: Int,
                                      seed: ((Album, URL) async throws -> Void)? = nil) async throws
        -> (album: Album, folder: URL, mediaIDs: [String]) {
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
        try await seed?(album, model.baseURL)
        return (album, model.baseURL, ids)
    }

    private func makeLoop(deviceResourceStateObserver: ICloudDriveBlobMigration.DeviceResourceStateObserver? = nil,
                          blobCache: CloudKitBlobCache? = nil,
                          store: CloudKitMediaStoring? = nil,
                          isUnlocked: @escaping @MainActor () -> Bool = { true },
                          hasNetwork: @escaping () -> Bool = { true },
                          isOnUnmeteredNetwork: @escaping () -> Bool = { true },
                          keyCache: BlobMigrationKeyCache? = nil,
                          fileVersions: ICloudDriveFileVersioning? = nil,
                          maxFailedDownloads: Int = ICloudDriveBlobMigration.defaultMaxFailedDownloads) -> ICloudDriveBlobMigration {
        let store: CloudKitMediaStoring = store ?? self.store!
        spy.store = store as? MockCloudKitMediaStore
        spy.inner = ICloudDriveVerifiedDelete(store: store,
                                              markerConflictVersions: { _ in [] })
        let spy = self.spy!
        return ICloudDriveBlobMigration(albumManager: albumManager,
                                        makeStore: { store },
                                        materializer: materializer,
                                        makeVerifiedDelete: { _ in spy },
                                        conditions: .init(isUnlocked: isUnlocked, hasNetwork: hasNetwork,
                                                          isOnUnmeteredNetwork: isOnUnmeteredNetwork,
                                                          hasICloudDrive: { true }),
                                        deviceState: { BlobMigrationDeviceState(isUnlocked: isUnlocked()) },
                                        markerConflictVersions: { _ in [] },
                                        keyCache: keyCache,
                                        deviceResourceStateObserver: deviceResourceStateObserver ?? deviceResourceState.observer,
                                        blobCache: blobCache ?? self.blobCache,
                                        fileVersions: fileVersions ?? FakeFileVersions(),
                                        maxFailedDownloads: maxFailedDownloads,
                                        finish: albumFinish)
    }

    /// The folder's listing on disk and its removal, real, with what iCloud
    /// Drive's metadata reports set by the test: nothing it can read until set.
    private final class FakeFolderContents: ICloudDriveAlbumFolderContents, @unchecked Sendable {
        private let lock = NSLock()
        private var reported: [String]?
        private var beforeRead: (() -> Void)?
        private let disk = ICloudDriveAlbumFolderDiskContents(metadataNames: { _ in nil })

        /// The names the metadata reports under any folder; nil when it cannot be read.
        var metadata: [String]? {
            get { lock.withLock { reported } }
            set { lock.withLock { reported = newValue } }
        }
        /// Runs as the metadata is read, after the folder was listed on disk.
        var onMetadataRead: (() -> Void)? {
            get { lock.withLock { beforeRead } }
            set { lock.withLock { beforeRead = newValue } }
        }

        func fileSystemNames(in folder: URL) -> [String]? {
            disk.fileSystemNames(in: folder)
        }

        func metadataNames(in folder: URL) async -> [String]? {
            onMetadataRead?()
            return metadata
        }

        func removeFolder(_ folder: URL, ifStillHolding holdsNothingElse: ([String]) -> Bool) throws -> Bool {
            try disk.removeFolder(folder, ifStillHolding: holdsNothingElse)
        }
    }

    /// The folder watch's change notifications, fired by the test.
    private final class FakeFolderChangeSource: ICloudDriveFolderChangeSource {
        private(set) var startedFolders: [URL] = []
        private(set) var stopCount = 0
        private var onChange: (@Sendable () -> Void)?

        nonisolated init() {}

        var isRunning: Bool { onChange != nil }

        func start(watching folder: URL, onChange: @escaping @Sendable () -> Void) {
            startedFolders.append(folder)
            self.onChange = onChange
        }

        func stop() {
            stopCount += 1
            onChange = nil
        }

        func fire() { onChange?() }
    }

    /// Power and thermal state a test sets, posted on its own center, with a
    /// clock it moves and the retries the loop scheduled.
    private final class FakeDeviceResourceState: @unchecked Sendable {
        private let lock = NSLock()
        private var lowPower = false
        private var thermal = ProcessInfo.ThermalState.nominal
        private var clock = Date()
        private var retries: [(delay: TimeInterval, retry: @MainActor () -> Void)] = []
        let center = NotificationCenter()
        static let accountChange = Notification.Name("FakeDeviceResourceState.accountChange")

        var now: Date {
            get { lock.withLock { clock } }
            set { lock.withLock { clock = newValue } }
        }
        var scheduledRetries: [(delay: TimeInterval, retry: @MainActor () -> Void)] { lock.withLock { retries } }

        var isLowPowerModeEnabled: Bool {
            get { lock.withLock { lowPower } }
            set { lock.withLock { lowPower = newValue } }
        }
        var thermalState: ProcessInfo.ThermalState {
            get { lock.withLock { thermal } }
            set { lock.withLock { thermal = newValue } }
        }

        @MainActor var observer: ICloudDriveBlobMigration.DeviceResourceStateObserver {
            ICloudDriveBlobMigration.DeviceResourceStateObserver(isLowPowerModeEnabled: { self.isLowPowerModeEnabled },
                                                                 thermalState: { self.thermalState },
                                                                 notificationCenter: center,
                                                                 accountChangeNotification: Self.accountChange,
                                                                 now: { self.now },
                                                                 scheduleRetry: { delay, retry in
                                                                     self.lock.withLock { self.retries.append((delay, retry)) }
                                                                 })
        }

        func postPowerChange() { center.post(name: .NSProcessInfoPowerStateDidChange, object: nil) }
        func postThermalChange() { center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil) }
        func postAccountChange() { center.post(name: Self.accountChange, object: nil) }
        func postNetworkChange() { center.post(name: NetworkMonitor.pathDidChange, object: nil) }
    }

    /// `NSFileVersion` as a test sets it: the unresolved conflict versions of each
    /// file, which a resolution removes, and what the store had seen when it ran.
    private final class FakeFileVersions: ICloudDriveFileVersioning, @unchecked Sendable {
        struct Resolution {
            let url: URL
            let storeCallsSoFar: [MockCloudKitMediaStore.Call]
            let deletesSoFar: [String]
        }

        private let lock = NSLock()
        private var versions: [URL: [URL]] = [:]
        private var resolutionsMade: [Resolution] = []
        var store: MockCloudKitMediaStore?
        var deletes: (() -> [String])?

        func setConflictVersions(_ urls: [URL], of url: URL) {
            lock.withLock { versions[url.standardizedFileURL] = urls }
        }
        var resolutions: [Resolution] { lock.withLock { resolutionsMade } }

        func unresolvedConflictVersionURLs(of url: URL) -> [URL] {
            lock.withLock { versions[url.standardizedFileURL] ?? [] }
        }

        func resolveConflicts(keepingCurrentVersionOf url: URL) throws {
            let calls = store?.callOrder ?? []
            let deletesSoFar = deletes?() ?? []
            lock.withLock {
                for version in versions[url.standardizedFileURL] ?? [] { try? FileManager.default.removeItem(at: version) }
                versions[url.standardizedFileURL] = nil
                resolutionsMade.append(Resolution(url: url, storeCallsSoFar: calls, deletesSoFar: deletesSoFar))
            }
        }
    }

    /// Waits until `condition` holds, failing after five seconds.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func photoRecordName(_ mediaID: String) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: .photo)
    }

    private func photoURL(_ prepared: Prepared, _ mediaID: String) -> URL {
        prepared.folder.appendingPathComponent("\(mediaID).\(MediaType.photo.encryptedFileExtension)")
    }

    private func mediaFiles(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !ICloudDriveAlbumMarkerFile.isMarkerFile($0) }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func plan(_ prepared: Prepared) async throws -> MigrationPlan {
        let loaded = await MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album,
                                              cloudKitAlbumID: prepared.albumID).load()
        return try XCTUnwrap(loaded)
    }

    private func state(of recordName: String, in plan: MigrationPlan) -> MigrationItemState? {
        plan.items.first { $0.recordName == recordName }?.state
    }

    private func indexEntries(_ prepared: Prepared) async -> [MediaIndexEntry] {
        await albumManager.mediaIndexStore(for: prepared.cloudKitAlbum).reloadFromDisk()?.entries ?? []
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try Data(contentsOf: url).count)
    }

    /// The record another device's upload left for `mediaID`'s photo.
    private func otherDeviceRecord(_ prepared: Prepared, mediaID: String, sizeBytes: Int64) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: photoRecordName(mediaID), albumID: prepared.albumID, mediaID: mediaID,
                              mediaType: .photo, createdAt: Date(), sizeBytes: sizeBytes,
                              creationDeviceID: "other-device", schemaVersion: 1, recordChangeTag: "tag")
    }

    // MARK: - Tests

    func testLoopCallsVerifiedDeleteRightAfterEachItemVerifies() async throws {
        let prepared = try await prepareAlbum(count: 3)

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(Set(report.deleted), Set(prepared.mediaIDs.map(photoRecordName)))
        XCTAssertEqual(spy.calls.count, 3, "one verified delete per item")
        for (position, call) in spy.calls.enumerated() {
            XCTAssertEqual(call.uploadsSoFar.count, position + 1,
                           "each delete comes after its own upload and before the next item's")
            XCTAssertEqual(call.uploadsSoFar.last, call.recordName, "the delete is for the item just uploaded")
            let calls = call.storeCallsSoFar
            let upload = try XCTUnwrap(calls.lastIndex(of: .upload(recordName: call.recordName)))
            XCTAssertTrue(calls[upload...].contains(.fetchRecordMetadata(recordName: call.recordName)),
                          "the record was verified after its upload, before the delete")
        }
        XCTAssertEqual(mediaFiles(in: prepared.folder), [], "every file went once its item verified")
        let plan = try await plan(prepared)
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .sourceDeleted }, "each delete is checkpointed")
        let entries = await indexEntries(prepared)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.photoLocation == .cloudKit }, "every component is in CloudKit")
    }

    func testItemDidFinishIsPostedOnceForEachItemsResult() async throws {
        let prepared = try await prepareAlbum(count: 3)
        let albumID = prepared.albumID
        var deletedWhenPosted: [Int] = []
        let observer = deviceResourceState.center.addObserver(forName: ICloudDriveBlobMigration.itemDidFinish,
                                                              object: nil, queue: nil) { note in
            guard note.userInfo?["albumID"] as? String == albumID else { return }
            MainActor.assumeIsolated { deletedWhenPosted.append(self.spy.calls.count) }
        }
        defer { deviceResourceState.center.removeObserver(observer) }

        let outcome = await makeLoop().runMigrationPass(albumID: albumID, folder: prepared.folder)

        guard case .finished = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(deletedWhenPosted, [1, 2, 3], "one post per item, each after that item's delete")
    }

    func testFailedVerificationDeletesNothing() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let failing = prepared.mediaIDs[0]
        let passing = prepared.mediaIDs[1]
        let failingBytes = try Data(contentsOf: photoURL(prepared, failing))
        // The server reports the record with a size that is not the file's.
        store.metadataToReturn = [otherDeviceRecord(prepared, mediaID: failing,
                                                    sizeBytes: Int64(failingBytes.count) + 1)]

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.failed, [photoRecordName(failing)])
        XCTAssertEqual(report.deleted, [photoRecordName(passing)], "the other item still moves")
        XCTAssertFalse(spy.calls.contains { $0.recordName == photoRecordName(failing) },
                       "an item that does not verify is never passed to the delete")
        XCTAssertTrue(ICloudPlaceholderName.isMaterialized(photoURL(prepared, failing)), "its file is kept")
        XCTAssertEqual(try fileSize(photoURL(prepared, failing)), Int64(failingBytes.count), "whole")
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: photoRecordName(failing), in: plan), .failed)
    }

    func testPreExistingRecordFromAnotherDeviceStillVerifies() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let mediaID = prepared.mediaIDs[0]
        let url = photoURL(prepared, mediaID)
        store.metadataToReturn = [otherDeviceRecord(prepared, mediaID: mediaID, sizeBytes: try fileSize(url))]
        store.uploadFailures[photoRecordName(mediaID)] = CloudKitMediaStoreError.partial(
            failed: [photoRecordName(mediaID): CKErrorFactory.error(.serverRecordChanged)])

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(store.uploadCalls, [mediaID], "the create was tried and conflicted")
        XCTAssertEqual(report.deleted, [photoRecordName(mediaID)], "the existing record verified")
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(url), "and its file was deleted")
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: photoRecordName(mediaID), in: plan), .sourceDeleted)
        let entry = await indexEntries(prepared).first { $0.id == mediaID }
        XCTAssertEqual(entry?.photoLocation, .cloudKit,
                       "a conflicted upload writes no entry, so the loop flips the location itself")
    }

    func testDeletesPerItemNotAfterWholeAlbum() async throws {
        let prepared = try await prepareAlbum(count: 3)
        let folder = prepared.folder
        let filesAtUpload = LockedBox<[Int]>([])
        store.onUploadStarted = { [weak self] in
            guard let self else { return }
            let count = await MainActor.run { self.mediaFiles(in: folder).count }
            filesAtUpload.mutate { $0.append(count) }
        }

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(filesAtUpload.value, [3, 2, 1],
                       "each upload starts with every earlier item's file already gone: one extra copy at a time")
        XCTAssertEqual(mediaFiles(in: prepared.folder), [])
    }

    /// Opened in the viewer, an item still on iCloud Drive migrates ahead of the
    /// rest, and its file goes as soon as its upload verifies.
    func testViewedItemMigratesFirst() async throws {
        let prepared = try await prepareAlbum(count: 3)
        let unrequestedPlan = try await plan(prepared)
        let order = BlobMigrationOrder.next(items: unrequestedPlan.items, deviceState: .unlocked,
                                            seed: BlobMigrationOrder.deviceSeed()).map(\.mediaID)
        let opened = try XCTUnwrap(order.last, "the item the migration would take last")
        let materializer = self.materializer!
        var iCloudDrive = CloudKitICloudDriveFolderAccess(makeMaterializer: { materializer })
        iCloudDrive.markerConflictVersions = { _ in [] }
        iCloudDrive.startMigrationPass = { _, _ in }
        let access = await CloudKitFileAccess(album: prepared.cloudKitAlbum, albumManager: albumManager,
                                              store: store, iCloudDrive: iCloudDrive)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(photoURL(prepared, opened)), mediaType: .photo, id: opened)
        ])

        _ = try await access.loadMediaForViewer(media: media, progress: { _ in })

        let requested = try await plan(prepared)
        XCTAssertEqual(requested.items.first { $0.mediaID == opened }?.priorityRequest?.reason, .viewed,
                       "the open asked for the item as viewed")
        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(store.uploadCalls.first, opened, "the viewed item migrates ahead of the rest")
        XCTAssertTrue(report.deleted.contains(photoRecordName(opened)), "its file goes once its upload verifies")
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(photoURL(prepared, opened)))
    }

    func testCreatedAtMatchesIndexEntryDate() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let moved = prepared.mediaIDs[0]
        let indexDate = Date(timeIntervalSinceReferenceDate: 12_345)
        let planned = try await plan(prepared).items.first { $0.mediaID == moved }?.createdAt
        XCTAssertNotEqual(planned, indexDate, "precondition: the plan holds another date")
        try await albumManager.mediaIndexStore(for: prepared.cloudKitAlbum).apply { entries in
            guard let position = entries.firstIndex(where: { $0.id == moved }) else { return }
            let entry = entries[position]
            entries[position] = MediaIndexEntry(id: entry.id, hasPhotoComponent: true, hasVideoComponent: false,
                                                dateEncrypted: Date(timeIntervalSinceReferenceDate: 99_999),
                                                dateTaken: indexDate, subtypeRawValue: entry.subtypeRawValue,
                                                photoLocation: .iCloudDrive)
        }
        let entries = await indexEntries(prepared)

        _ = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        XCTAssertEqual(store.uploadedItems.count, 2)
        for upload in store.uploadedItems {
            let entry = try XCTUnwrap(entries.first { $0.id == upload.mediaID })
            XCTAssertEqual(upload.createdAt, entry.dateTaken ?? entry.dateEncrypted,
                           "the record's createdAt is the index entry's date")
        }
        XCTAssertEqual(store.uploadedItems.first { $0.mediaID == moved }?.createdAt, indexDate)
    }

    /// A prepared album holding one legacy ENC2 video over the chunking threshold.
    private struct LegacyVideo {
        let prepared: Prepared
        let videoID: String
        let plaintext: Data
        let url: URL
        var recordName: String { MediaRecordName.componentRecordName(mediaID: videoID, type: .video) }
    }

    private func prepareLegacyVideo(store: CloudKitMediaStoring? = nil) async throws -> LegacyVideo {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        let videoID = UUID().uuidString
        var plaintext = Data(count: SeekableEncryptedFormat.threshold + 1024 * 1024)
        plaintext.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let key = self.key!
        let scratch = self.scratch!
        let prepared = try await prepareAlbum(count: 0, store: store) { album, folder in
            let plaintextURL = scratch.appendingPathComponent("\(videoID).mov")
            try plaintext.write(to: plaintextURL)
            let handler = SecretFileHandlerV2(keyBytes: key.keyBytes,
                                              source: CleartextMedia(source: plaintextURL, mediaType: .video, id: videoID),
                                              targetURL: folder.appendingPathComponent("\(videoID).\(MediaType.video.encryptedFileExtension)"))
            _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
            try FileManager.default.removeItem(at: plaintextURL)
        }
        let url = prepared.folder.appendingPathComponent("\(videoID).\(MediaType.video.encryptedFileExtension)")
        return LegacyVideo(prepared: prepared, videoID: videoID, plaintext: plaintext, url: url)
    }

    /// Counts the re-encryption's scratch directories and ENC3 writes while it is
    /// installed.
    private final class ReencryptionWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var directories: [URL] = []
        private var writes = 0

        var scratchDirectories: [URL] { lock.withLock { directories } }
        var enc3Writes: Int { lock.withLock { writes } }

        @MainActor
        init() {
            MigrationReencryptScratch.onMakeDirectoryForTesting = { [unowned self] url in
                self.lock.withLock { self.directories.append(url) }
            }
            LocalToCloudKitStep.afterReencryptWriteForTesting = { [unowned self] _ in
                self.lock.withLock { self.writes += 1 }
            }
        }

        @MainActor
        func remove() {
            MigrationReencryptScratch.onMakeDirectoryForTesting = nil
            LocalToCloudKitStep.afterReencryptWriteForTesting = nil
        }
    }

    func testLegacyLargeVideoIsReencryptedToENC3() async throws {
        let legacy = try await prepareLegacyVideo()
        let prepared = legacy.prepared
        let videoID = legacy.videoID
        let plaintext = legacy.plaintext
        let key = self.key!
        let scratch = self.scratch!
        let videoURL = legacy.url
        XCTAssertFalse(SeekableEncryptedHeader.isSeekableFormat(fileURL: videoURL), "precondition: the file is legacy ENC2")
        let originalSize = try fileSize(videoURL)
        let recordName = MediaRecordName.componentRecordName(mediaID: videoID, type: .video)
        let plannedKind = try await plan(prepared).items.first { $0.recordName == recordName }?.kind
        XCTAssertEqual(plannedKind, .encrypting)

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deleted, [recordName])
        let upload = try XCTUnwrap(store.uploadedItems.first { $0.recordName == recordName })
        XCTAssertGreaterThan(upload.chunkCount, 0, "the record is a chunked ENC3 record")
        XCTAssertEqual(upload.sizeBytes, originalSize, "it carries the original's size, which the delete verifies")
        let uploadedURL = scratch.appendingPathComponent("uploaded.enc3")
        try XCTUnwrap(store.uploadedBlobBytes[recordName]).write(to: uploadedURL)
        XCTAssertTrue(SeekableEncryptedHeader.isSeekableFormat(fileURL: uploadedURL), "ENC3 bytes were uploaded")
        let reader = try SeekableEncryptedReader.forFile(uploadedURL, keyBytes: key.keyBytes)
        let decrypted = try await reader.plaintext(range: 0..<reader.geometry.plaintextLength)
        XCTAssertTrue(decrypted == plaintext, "the ENC3 copy decrypts to the original video")
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(videoURL), "the ENC2 file was deleted once verified")
    }

    func testSkipsReencryptionWhenRecordAlreadyExists() async throws {
        let legacy = try await prepareLegacyVideo()
        let originalSize = try fileSize(legacy.url)
        // Another device's re-encrypted upload committed the record into this album.
        store.metadataToReturn = [CloudKitMediaMetadata(
            descriptor: CloudKitMediaRecordDescriptor(albumID: legacy.prepared.albumID, mediaID: legacy.videoID,
                                                      recordName: legacy.recordName, mediaType: .video,
                                                      createdAt: Date(), sizeBytes: originalSize,
                                                      keyFingerprint: "fp", chunkCount: 3, plaintextLength: 10),
            creationDeviceID: "other-device", schemaVersion: CloudKitSchema.currentSchemaVersion,
            recordChangeTag: "tag")]
        let watch = ReencryptionWatch()
        defer { watch.remove() }

        let outcome = await makeLoop().runMigrationPass(albumID: legacy.prepared.albumID, folder: legacy.prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(watch.scratchDirectories, [], "no scratch directory was made: no plaintext was written")
        XCTAssertEqual(watch.enc3Writes, 0, "no ENC3 file was written")
        XCTAssertFalse(store.callOrder.contains(.upload(recordName: legacy.recordName)),
                       "nothing was uploaded over the committed record")
        XCTAssertTrue(store.callOrder.contains(.fetchRecordMetadata(recordName: legacy.recordName)),
                      "the existing record was verified")
        XCTAssertEqual(report.deleted, [legacy.recordName], "it verified and its file was deleted")
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(legacy.url))
        let plan = try await plan(legacy.prepared)
        XCTAssertEqual(state(of: legacy.recordName, in: plan), .sourceDeleted)
    }

    func testLeftoverChunksWithoutRecordAreOverwritten() async throws {
        let chunks = InMemoryChunkedBlobStore()
        let memoryStore = InMemoryCloudKitMediaStore(chunkStore: chunks)
        let legacy = try await prepareLegacyVideo(store: memoryStore)
        let originalSize = try fileSize(legacy.url)
        // An earlier encryption's chunks, left by an upload that never committed.
        let plaintextURL = scratch.appendingPathComponent("leftover.mov")
        let leftoverURL = scratch.appendingPathComponent("leftover.enc3")
        try legacy.plaintext.write(to: plaintextURL)
        let leftoverHeader = try SeekableEncryptedWriter(keyBytes: key.keyBytes)
            .encrypt(source: plaintextURL, destination: leftoverURL)
        try await chunks.uploadChunks(enc3FileURL: leftoverURL, mediaRecordName: legacy.recordName,
                                      existingChunks: .overwrite, progress: { _ in })
        var leftover: [Data] = []
        for index in 0..<leftoverHeader.chunkCount {
            leftover.append(try await chunks.fetchChunk(mediaRecordName: legacy.recordName, index: index))
        }
        let before = try await memoryStore.fetchRecordMetadata(recordName: legacy.recordName)
        XCTAssertNil(before, "precondition: no record, only chunks")
        let watch = ReencryptionWatch()
        defer { watch.remove() }

        let outcome = await makeLoop(store: memoryStore).runMigrationPass(albumID: legacy.prepared.albumID,
                                                             folder: legacy.prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(watch.scratchDirectories.count, 1, "the video was re-encrypted")
        XCTAssertEqual(watch.enc3Writes, 1)
        XCTAssertEqual(report.deleted, [legacy.recordName], "it uploaded, verified and its file was deleted")
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(legacy.url))
        let fetched = try await memoryStore.fetchRecordMetadata(recordName: legacy.recordName)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.sizeBytes, originalSize)
        XCTAssertEqual(record.chunkCount, leftoverHeader.chunkCount)

        // The committed header and the chunks now on the server are one encryption.
        var assembled = try XCTUnwrap(record.encHeader)
        for index in 0..<record.chunkCount {
            let chunk = try await chunks.fetchChunk(mediaRecordName: legacy.recordName, index: index)
            XCTAssertNotEqual(chunk, leftover[index], "chunk \(index) was overwritten")
            assembled.append(chunk)
        }
        let assembledURL = scratch.appendingPathComponent("assembled.enc3")
        try assembled.write(to: assembledURL)
        let reader = try SeekableEncryptedReader.forFile(assembledURL, keyBytes: key.keyBytes)
        let decrypted = try await reader.plaintext(range: 0..<reader.geometry.plaintextLength)
        XCTAssertTrue(decrypted == legacy.plaintext, "the record's chunks decrypt to the original video")
    }

    // MARK: - Pause on power and heat

    func testLowPowerModePausesWithCause() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let device = deviceResourceState!
        // Low Power Mode comes on while the first item uploads.
        store.onUploadStarted = { device.isLowPowerModeEnabled = true }

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.paused(.lowPowerMode), let report) = outcome else {
            return XCTFail("expected a Low Power Mode pause, got \(outcome)")
        }
        XCTAssertEqual(report.deleted.count, 1, "the item under way finishes")
        XCTAssertEqual(store.uploadCalls.count, 1, "no new item is taken while Low Power Mode is on")
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .lowPowerMode,
                       "the reason is exposed for the album")
        XCTAssertFalse(ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID))

        store.onUploadStarted = nil
        device.postPowerChange()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.uploadCalls.count, 1, "a change that leaves Low Power Mode on resumes nothing")
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .lowPowerMode)

        device.isLowPowerModeEnabled = false
        device.postPowerChange()

        try await waitUntil("the paused album's pass runs again and ends") {
            store.uploadCalls.count == 2 && !ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID)
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), "the scheduled resume is gone")
        XCTAssertEqual(mediaFiles(in: prepared.folder), [], "the resumed pass moved the rest")
    }

    func testSeriousThermalStatePausesWithCause() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let device = deviceResourceState!
        device.thermalState = .serious

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.paused(.thermalState(.serious)), let report) = outcome else {
            return XCTFail("expected a thermal pause, got \(outcome)")
        }
        XCTAssertEqual(report, .init())
        XCTAssertEqual(store.uploadCalls, [], "nothing is taken while the device is hot")
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .thermalState(.serious))

        device.thermalState = .critical
        device.postThermalChange()
        try await waitUntil("the reason follows the thermal state") {
            ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID) == .thermalState(.critical)
        }
        XCTAssertEqual(store.uploadCalls, [], "critical holds the album too")

        device.thermalState = .fair
        device.postThermalChange()

        try await waitUntil("the paused album's pass runs again and ends") {
            store.uploadCalls.count == 1 && !ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID)
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
        XCTAssertEqual(mediaFiles(in: prepared.folder), [], "a fair thermal state does not pause")
    }

    // MARK: - Blob cache

    /// A viewed blob cached before the move and a later one cached after it:
    /// a migration upload goes in behind both, so the next eviction takes it and
    /// not the viewed media.
    func testMigrationUploadsInsertedColdInBlobCache() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let recordName = photoRecordName(prepared.mediaIDs[0])
        let uploadBytes = try fileSize(photoURL(prepared, prepared.mediaIDs[0]))
        let cache = try await cacheHoldingViewedMedia(roomFor: uploadBytes)

        let outcome = await makeLoop(blobCache: cache).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deleted, [recordName])
        let cachedUpload = await cache.cachedSize(recordName: recordName, changeTag: nil)
        XCTAssertEqual(cachedUpload, uploadBytes, "the upload is in the cache")

        try await cache.store(recordName: "next-viewed", changeTag: nil, albumID: prepared.albumID,
                              from: viewedSource())

        let afterEviction = await cachedNames(in: cache, ["viewed-1", "viewed-2", recordName, "next-viewed"])
        XCTAssertEqual(afterEviction, ["viewed-1", "viewed-2", "next-viewed"],
                       "the migration upload is evicted first, and every viewed blob stays")
    }

    /// An item migrated because it was viewed goes in as the most recently used:
    /// the next eviction takes the oldest viewed blob and keeps the upload.
    func testViewedItemUploadInsertedWarmInBlobCache() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let recordName = photoRecordName(prepared.mediaIDs[0])
        let uploadBytes = try fileSize(photoURL(prepared, prepared.mediaIDs[0]))
        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album, cloudKitAlbumID: prepared.albumID)
        let items = try await plan(prepared).items
        try await planStore.prioritize(items, reason: .viewed)
        let cache = try await cacheHoldingViewedMedia(roomFor: uploadBytes)

        let outcome = await makeLoop(blobCache: cache).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deleted, [recordName])

        try await cache.store(recordName: "next-viewed", changeTag: nil, albumID: prepared.albumID,
                              from: viewedSource())

        let afterEviction = await cachedNames(in: cache, ["viewed-1", "viewed-2", recordName, "next-viewed"])
        XCTAssertEqual(afterEviction, ["viewed-2", recordName, "next-viewed"],
                       "the viewed item's upload is warm: the oldest viewed blob goes instead")
    }

    private static let viewedBytes = 64

    private func viewedSource() throws -> URL {
        let url = scratch.appendingPathComponent("viewed-\(UUID().uuidString)")
        try Data(repeating: 0x5A, count: Self.viewedBytes).write(to: url)
        return url
    }

    /// A cache with two viewed blobs, opened in order, and exactly room for
    /// them plus an upload of `uploadBytes`: one more viewed blob evicts.
    private func cacheHoldingViewedMedia(roomFor uploadBytes: Int64) async throws -> CloudKitBlobCache {
        XCTAssertGreaterThanOrEqual(uploadBytes, Int64(Self.viewedBytes),
                                    "precondition: evicting the upload frees room for one viewed blob")
        let cache = CloudKitBlobCache(baseDir: scratch.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true),
                                      maxBytes: 2 * Int64(Self.viewedBytes) + uploadBytes)
        for name in ["viewed-1", "viewed-2"] {
            try await cache.store(recordName: name, changeTag: nil, albumID: "viewed", from: viewedSource())
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return cache
    }

    private func cachedNames(in cache: CloudKitBlobCache, _ names: [String]) async -> [String] {
        var cached: [String] = []
        for name in names where await cache.cachedSize(recordName: name, changeTag: nil) != nil {
            cached.append(name)
        }
        return cached
    }

    // MARK: - Run-halting failures

    private func quotaError(_ recordName: String) -> Error {
        CloudKitMediaStoreError.partial(failed: [recordName: CKErrorFactory.error(.quotaExceeded)])
    }

    /// Records each `.iCloudDrive` component's file size in the album's size
    /// sidecar, as the folder scanner does from iCloud Drive's metadata, which a
    /// scratch folder on the Mac has none of.
    private func recordICloudDriveSizes(_ prepared: Prepared) async throws {
        let entries = await indexEntries(prepared)
        var sizes: [String: Int64] = [:]
        for entry in entries where entry.photoLocation == .iCloudDrive {
            sizes[photoRecordName(entry.id)] = try fileSize(photoURL(prepared, entry.id))
        }
        try await albumManager.sizeSidecar(for: prepared.cloudKitAlbum)
            .apply(updates: sizes, removals: [], owner: .iCloudDrive, entries: entries)
    }

    private func readSource(_ prepared: Prepared, _ mediaID: String) async throws -> CloudKitResolvedComponent {
        let access = await CloudKitFileAccess(album: prepared.cloudKitAlbum, albumManager: albumManager, store: store)
        return try await access.resolveComponent(id: mediaID, type: .photo, progress: { _ in })
    }

    func testQuotaFailurePausesWithoutAlert() async throws {
        let (album, folder, ids) = try await makeICloudDriveAlbum(count: 2)
        for id in ids { store.uploadFailures[photoRecordName(id)] = quotaError(photoRecordName(id)) }
        let loop = makeLoop()
        var passOutcome: ICloudDriveBlobMigration.MigrationRunOutcome?
        let step = makeAlbumStep { albumID, folder in
            self.touchedAlbumIDs.insert(albumID)
            passOutcome = await loop.runMigrationPass(albumID: albumID, folder: folder)
        }
        let store = self.store!
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store },
                                               materializer: materializer,
                                               makeICloudDriveAlbumMigration: { _ in step })
        var states: [MigrationState] = []
        let subscription = manager.$state.sink { states.append($0) }
        defer { subscription.cancel() }

        // The user's start of the move: the album step, then the blob loop.
        let started = await manager.start(album: album, trigger: .user)

        XCTAssertTrue(started)
        guard case .stopped(.paused(.quota), let report)? = passOutcome else {
            return XCTFail("expected a quota pause, got \(String(describing: passOutcome))")
        }
        XCTAssertEqual(report.failed, [], "a full iCloud fails no item")
        XCTAssertEqual(store.uploadCalls.count, 1, "the loop stops at the first full-iCloud failure")
        let albumID = try XCTUnwrap(touchedAlbumIDs.first)
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: albumID), .quota, "the reason is exposed for the banner")

        // The alert hook: a run ending `.failed` is what the album screen's
        // blocking alert and the floating task's failure show.
        XCTAssertEqual(manager.state, .completed)
        XCTAssertFalse(states.contains { if case .failed = $0 { return true }; return false },
                       "the move never reported a failure: no alert")
        let resumable = await manager.pendingPlans()
        XCTAssertEqual(resumable.count, 0, "and no failed plan for launch resume or its prompts")

        let cloudKitAlbum = try XCTUnwrap(albumManager.cloudKitAlbum(withID: albumID))
        let prepared = Prepared(albumID: albumID, folder: folder, album: album, mediaIDs: ids, cloudKitAlbum: cloudKitAlbum)
        let plan = try await plan(prepared)
        XCTAssertEqual(plan.items.map(\.state), [.pending, .pending], "the items stay pending, not failed")
        XCTAssertEqual(plan.lastFailure?.category, .quota)

        // Still browsable and editable while paused. The rename's record save is
        // left out: it would reach the real CloudKit container.
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        XCTAssertTrue(albumManager.fetchAlbumsFromSources().contains { $0.id == cloudKitAlbum.id }, "the album is listed")
        for id in ids {
            let read = try await readSource(prepared, id)
            XCTAssertEqual(read.source, .iCloudDriveFile, "each item still reads from its iCloud Drive file")
        }
        let renamed = try albumManager.renameAlbum(album: cloudKitAlbum, to: "renamed-\(UUID().uuidString)")
        XCTAssertTrue(albumManager.fetchAlbumsFromSources().contains { $0.id == cloudKitAlbum.id && $0.name == renamed.name },
                      "a rename goes through while the move is paused")
    }

    func testQuotaPauseExposesBytesStillNeeded() async throws {
        let prepared = try await prepareAlbum(count: 3)
        let deferred = prepared.mediaIDs[0]
        let movable = Array(prepared.mediaIDs.dropFirst())
        // One item is deferred: it is not bytes the album still needs.
        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album, cloudKitAlbumID: prepared.albumID)
        var seeded = try await plan(prepared)
        let deferredIndex = try XCTUnwrap(seeded.items.firstIndex { $0.mediaID == deferred })
        seeded.items[deferredIndex].deferralReason = .unreadable
        try await planStore.save(seeded)
        try await recordICloudDriveSizes(prepared)
        for id in movable { store.uploadFailures[photoRecordName(id)] = quotaError(photoRecordName(id)) }
        let expected = try movable.reduce(Int64(0)) { $0 + (try fileSize(photoURL(prepared, $1))) }

        // The deferred item comes last, so the quota pause stops the pass first.
        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.paused(.quota), _) = outcome else { return XCTFail("expected a quota pause, got \(outcome)") }
        XCTAssertEqual(ICloudDriveBlobMigration.bytesStillNeeded(albumID: prepared.albumID), expected,
                       "the bytes of the components still on iCloud Drive that are not deferred")
        let bytes = await albumManager.mediaBytes(for: prepared.cloudKitAlbum)
        XCTAssertEqual(bytes.remainingOnICloudDrive, expected)
        XCTAssertEqual(bytes.deferredOnICloudDrive, try fileSize(photoURL(prepared, deferred)))

        // The existing quota retry interval holds every pass off.
        let retry = try XCTUnwrap(deviceResourceState.scheduledRetries.last)
        XCTAssertEqual(retry.delay, MigrationLastFailure.quotaRetryInterval, accuracy: 1)
        let uploadsAtPause = store.uploadCalls.count
        deviceResourceState.now = deviceResourceState.now.addingTimeInterval(MigrationLastFailure.quotaRetryInterval - 60)
        let early = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        guard case .stopped(.paused(.quota), _) = early else { return XCTFail("expected a quota pause, got \(early)") }
        XCTAssertEqual(store.uploadCalls.count, uploadsAtPause, "nothing is tried inside the interval")
        XCTAssertEqual(ICloudDriveBlobMigration.bytesStillNeeded(albumID: prepared.albumID), expected,
                       "the state holds until progress resumes")

        // Once the interval has passed the retry moves the rest, the deferred
        // item last: its bytes are readable after all, so its retry moves it.
        store.uploadFailures = [:]
        deviceResourceState.now = deviceResourceState.now.addingTimeInterval(120)
        try XCTUnwrap(deviceResourceState.scheduledRetries.last).retry()
        try await waitUntil("the retried pass moves the rest") {
            self.mediaFiles(in: prepared.folder).isEmpty
                && !ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID)
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
        XCTAssertNil(ICloudDriveBlobMigration.bytesStillNeeded(albumID: prepared.albumID))
        let after = try await plan(prepared)
        XCTAssertNil(after.lastFailure, "progress clears the recorded quota failure")
    }

    func testNoAccountAndUndeployedSchemaPause() async throws {
        // No account when the pass starts.
        let signedOut = try await prepareAlbum(count: 1)
        store.accountAvailableValue = false
        let first = await makeLoop().runMigrationPass(albumID: signedOut.albumID, folder: signedOut.folder)
        guard case .stopped(.paused(.accountUnavailable), _) = first else {
            return XCTFail("expected an account pause, got \(first)")
        }
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: signedOut.albumID), .accountUnavailable)
        XCTAssertEqual(store.uploadCalls, [])
        store.accountAvailableValue = true
        deviceResourceState.postPowerChange()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.uploadCalls, [], "a power change does not resume an account pause")
        deviceResourceState.postAccountChange()
        try await waitUntil("the account change resumes the album") {
            self.mediaFiles(in: signedOut.folder).isEmpty && !ICloudDriveBlobMigration.isRunning(albumID: signedOut.albumID)
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: signedOut.albumID))

        // The account goes during an upload.
        let lost = try await prepareAlbum(count: 1)
        let lostName = photoRecordName(lost.mediaIDs[0])
        store.uploadFailures[lostName] = CloudKitMediaStoreError.partial(failed: [lostName: CKErrorFactory.error(.notAuthenticated)])
        let second = await makeLoop().runMigrationPass(albumID: lost.albumID, folder: lost.folder)
        guard case .stopped(.paused(.accountUnavailable), let lostReport) = second else {
            return XCTFail("expected an account pause, got \(second)")
        }
        XCTAssertEqual(lostReport.failed, [])
        let lostState = state(of: lostName, in: try await plan(lost))
        XCTAssertEqual(lostState, .pending, "the item is not failed")

        // The Production schema was never deployed.
        let undeployed = try await prepareAlbum(count: 1)
        let name = photoRecordName(undeployed.mediaIDs[0])
        store.uploadFailures[name] = CloudKitMediaStoreError.partial(failed: [name: CKErrorFactory.error(.invalidArguments)])
        let third = await makeLoop().runMigrationPass(albumID: undeployed.albumID, folder: undeployed.folder)
        guard case .stopped(.paused(.schemaNotDeployed), let report) = third else {
            return XCTFail("expected a schema pause, got \(third)")
        }
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: undeployed.albumID), .schemaNotDeployed)
        let undeployedPlan = try await plan(undeployed)
        XCTAssertEqual(state(of: name, in: undeployedPlan), .pending, "the item is not failed")
        XCTAssertNil(undeployedPlan.lastFailure)
        let undeployedUploads = { self.store.uploadCalls.filter { $0 == undeployed.mediaIDs[0] }.count }
        XCTAssertEqual(undeployedUploads(), 1)
        deviceResourceState.postAccountChange()
        deviceResourceState.postPowerChange()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(undeployedUploads(), 1, "nothing in this process retries an undeployed schema")
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: undeployed.albumID), .schemaNotDeployed)
    }

    // MARK: - Deferred items

    func testCorruptItemIsDeferredAndStaysReadable() async throws {
        let corruptID = UUID().uuidString
        var garbage = Data(count: 600)
        garbage.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let prepared = try await prepareAlbum(count: 1) { _, folder in
            try garbage.write(to: folder.appendingPathComponent("\(corruptID).\(MediaType.photo.encryptedFileExtension)"))
        }
        let corrupt = photoRecordName(corruptID)
        let corruptURL = photoURL(prepared, corruptID)
        try await recordICloudDriveSizes(prepared)

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deferredItems, [corrupt: .unreadable])
        XCTAssertEqual(report.deleted, [photoRecordName(prepared.mediaIDs[0])], "the other item moves")
        XCTAssertFalse(store.uploadCalls.contains(corruptID), "nothing was uploaded for it")
        let plan = try await plan(prepared)
        let item = try XCTUnwrap(plan.items.first { $0.recordName == corrupt })
        XCTAssertEqual(item.state, .pending, "not done")
        XCTAssertEqual(item.deferralReason, .unreadable)
        XCTAssertEqual(plan.deferredCount, 1, "counted as can't be moved right now")
        let counted = await ICloudDriveBlobMigration.deferredCount(for: prepared.cloudKitAlbum)
        XCTAssertEqual(counted, 1)

        // Still viewable from iCloud Drive.
        XCTAssertEqual(try Data(contentsOf: corruptURL), garbage, "its file is kept whole")
        let corruptEntry = await indexEntries(prepared).first { $0.id == corruptID }
        XCTAssertEqual(corruptEntry?.photoLocation, .iCloudDrive)
        let read = try await readSource(prepared, corruptID)
        XCTAssertEqual(read.source, .iCloudDriveFile)
        XCTAssertEqual(try Data(contentsOf: read.url), garbage)

        // Work remains, but not bytes still to move.
        XCTAssertTrue(plan.hasRemainingWork)
        XCTAssertTrue(ICloudDriveBlobMigration.hasPendingPlans(), "passes keep being scheduled for it")
        let bytes = await albumManager.mediaBytes(for: prepared.cloudKitAlbum)
        XCTAssertEqual(bytes.remainingOnICloudDrive, 0)
        XCTAssertEqual(bytes.deferredOnICloudDrive, Int64(garbage.count))

        // Off Wi-Fi a pass stops before any item.
        let callsBefore = store.callOrder.count
        let offWiFi = await makeLoop(isOnUnmeteredNetwork: { false }).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        guard case .stopped(.paused(.waitingForWiFi), let offWiFiReport) = offWiFi else {
            return XCTFail("expected a stop waiting for Wi-Fi, got \(offWiFi)")
        }
        XCTAssertEqual(offWiFiReport, .init(), "the pass waits for Wi-Fi")
        XCTAssertEqual(store.callOrder.count, callsBefore, "nothing reaches CloudKit off Wi-Fi")

        // On Wi-Fi it is tried again, and still unreadable it stays deferred.
        let again = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        guard case .finished(let againReport) = again else { return XCTFail("expected finished, got \(again)") }
        XCTAssertEqual(againReport.deferredItems, [corrupt: .unreadable])
        let after = try await self.plan(prepared)
        XCTAssertEqual(state(of: corrupt, in: after), .pending)
        XCTAssertEqual(after.items.first { $0.recordName == corrupt }?.deferralReason, .unreadable)
        XCTAssertEqual(try Data(contentsOf: corruptURL), garbage)
    }

    // MARK: - Wi-Fi only

    func testPassOffWiFiStopsBeforeMaterializing() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let url = photoURL(prepared, prepared.mediaIDs[0])
        try materializer.evictForTest(url)
        let materializeCalls = LockedBox(0)
        materializer.onMaterialize = { _ in materializeCalls.mutate { $0 += 1 } }
        let before = try await plan(prepared)
        let callsBefore = store.callOrder.count

        let outcome = await makeLoop(isOnUnmeteredNetwork: { false })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.paused(.waitingForWiFi), let report) = outcome else {
            return XCTFail("expected a stop waiting for Wi-Fi, got \(outcome)")
        }
        XCTAssertEqual(report, .init())
        XCTAssertEqual(materializeCalls.value, 0, "nothing is downloaded from iCloud Drive off Wi-Fi")
        XCTAssertEqual(store.uploadCalls, [])
        XCTAssertEqual(store.callOrder.count, callsBefore, "no CloudKit request off Wi-Fi")
        let after = try await plan(prepared)
        XCTAssertEqual(after.items, before.items, "no item changes state")
        XCTAssertFalse(ICloudPlaceholderName.isMaterialized(url))
    }

    func testBackgroundTaskRunOffWiFiTouchesNoItem() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let before = try await plan(prepared)
        let callsBefore = store.callOrder.count

        let report = await makeLoop(isOnUnmeteredNetwork: { false }).runBackgroundTaskPasses()

        XCTAssertEqual(report.outcomes[prepared.albumID], .stopped(.paused(.waitingForWiFi), .init()))
        XCTAssertEqual(store.uploadCalls, [])
        XCTAssertEqual(store.callOrder.count, callsBefore, "no CloudKit request off Wi-Fi")
        let after = try await plan(prepared)
        XCTAssertEqual(after.items, before.items, "no item changes state")
    }

    func testPassOffWiFiPausesAlbumUntilWiFiReturns() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let onWiFi = LockedBox(false)
        let pauseChanges = LockedBox(0)
        let observer = deviceResourceState.center.addObserver(forName: ICloudDriveBlobMigration.pauseStateDidChange,
                                                              object: nil, queue: nil) { note in
            guard note.userInfo?["albumID"] as? String == prepared.albumID else { return }
            pauseChanges.mutate { $0 += 1 }
        }
        defer { deviceResourceState.center.removeObserver(observer) }

        let outcome = await makeLoop(isOnUnmeteredNetwork: { onWiFi.value })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.paused(.waitingForWiFi), _) = outcome else {
            return XCTFail("expected a stop waiting for Wi-Fi, got \(outcome)")
        }
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .waitingForWiFi)
        XCTAssertEqual(pauseChanges.value, 1, "the pause is posted")

        deviceResourceState.postNetworkChange()
        deviceResourceState.postPowerChange()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.uploadCalls, [], "a network change still off Wi-Fi, or a power change, does not resume it")
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .waitingForWiFi)

        onWiFi.mutate { $0 = true }
        deviceResourceState.postNetworkChange()
        try await waitUntil("Wi-Fi coming back resumes the album") {
            self.mediaFiles(in: prepared.folder).isEmpty && !ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID)
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
        XCTAssertGreaterThanOrEqual(pauseChanges.value, 2, "the resume is posted")
    }

    func testShownPauseReasonIsWaitingForWiFiOffWiFiWithoutAHeldPause() async throws {
        let prepared = try await prepareAlbum(count: 1)
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
        XCTAssertEqual(ICloudDriveBlobMigration.shownPauseReason(albumID: prepared.albumID, isOnUnmeteredNetwork: false),
                       .waitingForWiFi, "a launch off Wi-Fi holds no pause, but nothing moves")
        XCTAssertNil(ICloudDriveBlobMigration.shownPauseReason(albumID: prepared.albumID, isOnUnmeteredNetwork: true))

        deviceResourceState.isLowPowerModeEnabled = true
        _ = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        XCTAssertEqual(ICloudDriveBlobMigration.shownPauseReason(albumID: prepared.albumID, isOnUnmeteredNetwork: false),
                       .lowPowerMode, "a held pause wins")
    }

    func testOfflineStopKeepsWiFiPause() async throws {
        let prepared = try await prepareAlbum(count: 1)
        _ = await makeLoop(isOnUnmeteredNetwork: { false })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .waitingForWiFi)

        let offline = await makeLoop(hasNetwork: { false }, isOnUnmeteredNetwork: { false })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.offline, _) = offline else { return XCTFail("expected an offline stop, got \(offline)") }
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .waitingForWiFi,
                       "offline is still no Wi-Fi")
    }

    func testOfflineStopWithoutAPausePausesUntilWiFiReturns() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let network = LockedBox(false)
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))

        let offline = await makeLoop(hasNetwork: { network.value }, isOnUnmeteredNetwork: { network.value })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.offline, _) = offline else { return XCTFail("expected an offline stop, got \(offline)") }
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .waitingForWiFi,
                       "no network at all waits for Wi-Fi too")

        network.mutate { $0 = true }
        deviceResourceState.postNetworkChange()
        try await waitUntil("Wi-Fi after an offline stop resumes the album") {
            self.mediaFiles(in: prepared.folder).isEmpty && !ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID)
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
    }

    func testOtherStopClearsWiFiPause() async throws {
        let prepared = try await prepareAlbum(count: 1)
        _ = await makeLoop(isOnUnmeteredNetwork: { false })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        XCTAssertEqual(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID), .waitingForWiFi)

        let missing = prepared.folder.deletingLastPathComponent().appendingPathComponent("not-the-album")
        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: missing)

        guard case .stopped(let reason, _) = outcome, reason != .paused(.waitingForWiFi), reason != .offline else {
            return XCTFail("expected a stop for another reason, got \(outcome)")
        }
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
    }

    func testNetworkUnavailableOffWiFiRequeuesItem() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let mediaID = prepared.mediaIDs[0]
        let recordName = photoRecordName(mediaID)
        let url = photoURL(prepared, mediaID)
        try materializer.evictForTest(url)
        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album, cloudKitAlbumID: prepared.albumID)
        var seeded = try await plan(prepared)
        let index = try XCTUnwrap(seeded.items.firstIndex { $0.recordName == recordName })
        seeded.items[index].deferralReason = .neverDownloads
        try await planStore.save(seeded)
        let onWiFi = LockedBox(true)
        store.onUploadStarted = { onWiFi.mutate { $0 = false } }
        store.uploadErrorOnce = CKError(.networkUnavailable)

        let outcome = await makeLoop(isOnUnmeteredNetwork: { onWiFi.value })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .stopped(.paused(.waitingForWiFi), let report) = outcome else {
            return XCTFail("expected a stop waiting for Wi-Fi, got \(outcome)")
        }
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(store.uploadCalls, [mediaID])
        let after = try await plan(prepared)
        let item = try XCTUnwrap(after.items.first { $0.recordName == recordName })
        XCTAssertEqual(item.state, .pending, "losing Wi-Fi is not the item's failure")
        XCTAssertEqual(item.deferralReason, .neverDownloads, "the item keeps its deferral reason")
        XCTAssertNil(item.lastError)
        XCTAssertFalse(ICloudPlaceholderName.isMaterialized(url), "the file this pass downloaded is evicted again")
    }

    func testNetworkUnavailableOnWiFiStillFailsItem() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let recordName = photoRecordName(prepared.mediaIDs[0])
        store.uploadErrorOnce = CKError(.networkUnavailable)

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.failed, [recordName], "on Wi-Fi a network error is the item's failure")
        XCTAssertEqual(report.requeued, [])
        let after = try await plan(prepared)
        XCTAssertEqual(state(of: recordName, in: after), .failed)
    }

    func testFailedDownloadOffWiFiNotCounted() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let mediaID = prepared.mediaIDs[0]
        let url = photoURL(prepared, mediaID)
        try materializer.evictForTest(url)
        materializer.urlsThatFailToMaterialize = [url.lastPathComponent]
        let onWiFi = LockedBox(true)
        // The phone moves to cellular during the download, keeping a network.
        materializer.onMaterialize = { _ in onWiFi.mutate { $0 = false } }

        _ = await makeLoop(hasNetwork: { true }, isOnUnmeteredNetwork: { onWiFi.value })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        let after = try await plan(prepared)
        XCTAssertNil(after.items.first { $0.mediaID == mediaID }?.failedDownloads,
                     "a download that failed after Wi-Fi went does not count")
    }

    func testNeverDownloadingPlaceholderIsDeferredAndStaysReadable() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let mediaID = prepared.mediaIDs[0]
        let recordName = photoRecordName(mediaID)
        let url = photoURL(prepared, mediaID)
        try materializer.evictForTest(url)
        materializer.urlsThatFailToMaterialize = [url.lastPathComponent]
        let network = LockedBox(true)
        func pass() async -> ICloudDriveBlobMigration.MigrationRunOutcome {
            await makeLoop(hasNetwork: { network.value }, isOnUnmeteredNetwork: { network.value }, maxFailedDownloads: 3)
                .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        }

        // A download that fails because the network went does not count.
        materializer.onMaterialize = { _ in network.mutate { $0 = false } }
        _ = await pass()
        materializer.onMaterialize = nil
        network.mutate { $0 = true }
        var plan = try await self.plan(prepared)
        XCTAssertNil(plan.items.first?.failedDownloads)
        XCTAssertEqual(state(of: recordName, in: plan), .failed, "retryable")

        for attempt in 1...2 {
            guard case .finished(let report) = await pass() else { return XCTFail("expected finished") }
            XCTAssertEqual(report.failed, [recordName], "attempt \(attempt) fails the item, still retryable")
            plan = try await self.plan(prepared)
            XCTAssertEqual(plan.items.first?.failedDownloads, attempt)
            XCTAssertEqual(state(of: recordName, in: plan), .failed)
        }

        guard case .finished(let report) = await pass() else { return XCTFail("expected finished") }
        XCTAssertEqual(report.deferredItems, [recordName: .neverDownloads], "the third failed download defers it")
        plan = try await self.plan(prepared)
        XCTAssertEqual(state(of: recordName, in: plan), .pending, "not done")
        XCTAssertEqual(plan.items.first?.deferralReason, .neverDownloads)
        XCTAssertEqual(plan.deferredCount, 1)
        XCTAssertTrue(ICloudPlaceholderName.existsInAnyForm(url), "its iCloud Drive file is kept")
        let entry = await indexEntries(prepared).first
        XCTAssertEqual(entry?.photoLocation, .iCloudDrive)
        XCTAssertTrue(ICloudDriveBlobMigration.hasPendingPlans())

        // A retry whose download fails again keeps it deferred.
        guard case .finished(let retry) = await pass() else { return XCTFail("expected finished") }
        XCTAssertEqual(retry.deferredItems, [recordName: .neverDownloads])
        XCTAssertEqual(retry.failed, [])
        plan = try await self.plan(prepared)
        XCTAssertEqual(plan.items.first?.deferralReason, .neverDownloads)
        XCTAssertEqual(state(of: recordName, in: plan), .pending)

        // Once it downloads, it moves.
        materializer.urlsThatFailToMaterialize = []
        guard case .finished(let moved) = await pass() else { return XCTFail("expected finished") }
        XCTAssertEqual(moved.deleted, [recordName])
        plan = try await self.plan(prepared)
        XCTAssertNil(plan.items.first?.deferralReason, "success clears the reason")
        XCTAssertNil(plan.items.first?.failedDownloads)
        XCTAssertFalse(plan.hasRemainingWork)
    }

    /// Writes a photo into the album's folder encrypted with `key`, which this
    /// device does not hold.
    private func writeForeignPhoto(_ mediaID: String, key: PrivateKey, into folder: URL) async throws {
        let cleartext = scratch.appendingPathComponent("\(mediaID).png")
        try TestImageData.png().write(to: cleartext)
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes,
                                          source: CleartextMedia(source: cleartext, mediaType: .photo, id: mediaID),
                                          targetURL: folder.appendingPathComponent("\(mediaID).\(MediaType.photo.encryptedFileExtension)"))
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
    }

    func testMissingKeyItemIsDeferredAndStaysReadable() async throws {
        let otherKey = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let foreignID = UUID().uuidString
        let prepared = try await prepareAlbum(count: 1) { _, folder in
            try await self.writeForeignPhoto(foreignID, key: otherKey, into: folder)
        }
        let foreign = photoRecordName(foreignID)
        let foreignURL = photoURL(prepared, foreignID)
        let foreignBytes = try Data(contentsOf: foreignURL)

        // A pass that started locked has only the keys held in memory, which may
        // be stale: it leaves the item retryable.
        let keyCache = BlobMigrationKeyCache()
        keyCache.refreshKeysFromKeychain(using: albumManager)
        let locked = await makeLoop(isUnlocked: { false }, keyCache: keyCache)
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        guard case .finished(let lockedReport) = locked else { return XCTFail("expected finished, got \(locked)") }
        XCTAssertEqual(lockedReport.failed, [foreign])
        XCTAssertEqual(lockedReport.deferredItems, [:])

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deferredItems, [foreign: .missingKey], "no key read from the keychain opens it")
        XCTAssertFalse(store.uploadCalls.contains(foreignID))
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: foreign, in: plan), .pending, "not done")
        XCTAssertEqual(plan.items.first { $0.recordName == foreign }?.deferralReason, .missingKey)
        XCTAssertEqual(plan.deferredCount, 1)
        XCTAssertEqual(try Data(contentsOf: foreignURL), foreignBytes, "its file is kept")
        let foreignEntry = await indexEntries(prepared).first { $0.id == foreignID }
        XCTAssertEqual(foreignEntry?.photoLocation, .iCloudDrive)
        XCTAssertTrue(ICloudDriveBlobMigration.hasPendingPlans())
    }

    func testMissingKeyItemMovesOnceTheKeyArrives() async throws {
        let otherKey = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let foreignID = UUID().uuidString
        let prepared = try await prepareAlbum(count: 1) { _, folder in
            try await self.writeForeignPhoto(foreignID, key: otherKey, into: folder)
        }
        let foreign = photoRecordName(foreignID)
        guard case .finished(let first) = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(first.deferredItems, [foreign: .missingKey])

        // The key arrives, through iCloud Keychain say.
        let keyManager = try XCTUnwrap(albumManager.keyManager as? DemoKeyManager)
        try keyManager.save(key: otherKey, setNewKeyToCurrent: false)

        // Not before the device is on Wi-Fi.
        guard case .stopped(.paused(.waitingForWiFi), let cellular) = await makeLoop(isOnUnmeteredNetwork: { false })
            .runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) else {
            return XCTFail("expected a stop waiting for Wi-Fi")
        }
        XCTAssertEqual(cellular, .init())
        XCTAssertFalse(store.uploadCalls.contains(foreignID))

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deleted, [foreign], "the next Wi-Fi pass moves it")
        XCTAssertEqual(report.deferredItems, [:])
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: foreign, in: plan), .sourceDeleted)
        XCTAssertNil(plan.items.first { $0.recordName == foreign }?.deferralReason)
        XCTAssertTrue(plan.isComplete, "the album has nothing left to move")
        XCTAssertFalse(plan.hasRemainingWork)
        XCTAssertEqual(mediaFiles(in: prepared.folder), [])
        let entry = await indexEntries(prepared).first { $0.id == foreignID }
        XCTAssertEqual(entry?.photoLocation, .cloudKit)
    }

    func testItemInAnotherAlbumIsDeferredNotSkipped() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let claimedID = prepared.mediaIDs[0]
        let claimed = photoRecordName(claimedID)
        store.confirmAlbumOverride[claimed] = .success("other-album")

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deferredItems, [claimed: .recordInAnotherAlbum])
        XCTAssertEqual(report.skipped, [], "never silently skipped")
        XCTAssertEqual(report.deleted, [photoRecordName(prepared.mediaIDs[1])])
        XCTAssertFalse(store.uploadCalls.contains(claimedID), "nothing saved over the other album's record")
        var plan = try await plan(prepared)
        XCTAssertEqual(state(of: claimed, in: plan), .pending)
        XCTAssertEqual(plan.items.first { $0.recordName == claimed }?.deferralReason, .recordInAnotherAlbum)
        XCTAssertEqual(plan.deferredCount, 1, "counted for the banner")
        XCTAssertTrue(plan.hasRemainingWork)
        XCTAssertEqual(mediaFiles(in: prepared.folder), [photoURL(prepared, claimedID).lastPathComponent], "its file is kept")

        // Once the record is no longer another album's, a Wi-Fi pass moves it.
        store.confirmAlbumOverride[claimed] = nil
        guard case .finished(let retry) = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(retry.deleted, [claimed])
        plan = try await self.plan(prepared)
        XCTAssertTrue(plan.isComplete)
    }

    func testDeferredItemMovedByAnotherDeviceEndsDone() async throws {
        let otherKey = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let foreignID = UUID().uuidString
        let prepared = try await prepareAlbum(count: 0) { _, folder in
            try await self.writeForeignPhoto(foreignID, key: otherKey, into: folder)
        }
        let foreign = photoRecordName(foreignID)
        let url = photoURL(prepared, foreignID)
        guard case .finished(let first) = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(first.deferredItems, [foreign: .missingKey])

        // Another device, which holds the key, uploads it; the feed marks the
        // component `.cloudKit` and the parity sweep's verified delete removes
        // this device's file.
        store.metadataToReturn = [otherDeviceRecord(prepared, mediaID: foreignID, sizeBytes: try fileSize(url))]
        try await albumManager.mediaIndexStore(for: prepared.cloudKitAlbum).apply { entries in
            guard let position = entries.firstIndex(where: { $0.id == foreignID }) else { return }
            entries[position] = entries[position].with(photoLocation: .cloudKit)
        }
        let sweepDelete = await ICloudDriveVerifiedDelete(store: store, markerConflictVersions: { _ in [] })
            .delete(recordName: foreign, albumID: prepared.albumID, folder: prepared.folder)
        guard case .deleted = sweepDelete else { return XCTFail("expected the verified delete to remove the file, got \(sweepDelete)") }
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(url))
        let beforeRetry = try await plan(prepared)
        XCTAssertTrue(beforeRetry.hasRemainingWork, "the plan does not know yet")

        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deferredItems, [:])
        XCTAssertFalse(store.uploadCalls.contains(foreignID), "nothing is uploaded again")
        let plan = try await plan(prepared)
        XCTAssertEqual(plan.items.first { $0.recordName == foreign }?.state.isDone, true, "the retry ends the item")
        XCTAssertNil(plan.items.first { $0.recordName == foreign }?.deferralReason)
        XCTAssertEqual(plan.deferredCount, 0)
        XCTAssertFalse(plan.hasRemainingWork, "nothing holds the album back")
    }

    /// Opens `mediaID` in the viewer through the CloudKit album's file access.
    /// The pass the open starts is run, to its end, by `linkingWith`; with none,
    /// the open starts nothing.
    private func openInViewer(_ prepared: Prepared, _ mediaID: String,
                              linkingWith loop: ICloudDriveBlobMigration? = nil) async throws {
        var iCloudDrive = CloudKitICloudDriveFolderAccess(makeMaterializer: { [materializer] in materializer! })
        iCloudDrive.markerConflictVersions = { _ in [] }
        let folder = prepared.folder
        iCloudDrive.startMigrationPass = { _, albumID in
            _ = await loop?.runMigrationPass(albumID: albumID, folder: folder)
        }
        let access = await CloudKitFileAccess(album: prepared.cloudKitAlbum, albumManager: albumManager, store: store,
                                              iCloudDrive: iCloudDrive)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(photoURL(prepared, mediaID)), mediaType: .photo, id: mediaID)
        ])
        _ = try await access.loadMediaForViewer(media: media, progress: { _ in })
    }

    func testOpeningICloudDriveItemLinksItRightAway() async throws {
        let prepared = try await prepareAlbum(count: 3)
        let loaded = try await plan(prepared)
        let order = BlobMigrationOrder.next(items: loaded.items, deviceState: .unlocked, seed: BlobMigrationOrder.deviceSeed())
        let opened = try XCTUnwrap(order.last?.mediaID, "the item the migration would take last")
        XCTAssertFalse(ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID), "precondition: no pass is running")

        try await openInViewer(prepared, opened, linkingWith: makeLoop())

        XCTAssertEqual(store.uploadCalls.first, opened, "the open starts a pass, which takes the opened item first")
        let entry = await indexEntries(prepared).first { $0.id == opened }
        XCTAssertEqual(entry?.photoLocation, .cloudKit, "the item is in CloudKit")
    }

    func testOpeningMissingKeyItemAfterKeyArrivesClearsDeferralAndLinksIt() async throws {
        let otherKey = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let foreignID = UUID().uuidString
        let prepared = try await prepareAlbum(count: 1) { _, folder in
            try await self.writeForeignPhoto(foreignID, key: otherKey, into: folder)
        }
        let foreign = photoRecordName(foreignID)
        guard case .finished(let first) = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(first.deferredItems, [foreign: .missingKey])
        let keyManager = try XCTUnwrap(albumManager.keyManager as? DemoKeyManager)
        try keyManager.save(key: otherKey, setNewKeyToCurrent: false)

        try await openInViewer(prepared, foreignID, linkingWith: makeLoop(isOnUnmeteredNetwork: { false }))

        var item = try await plan(prepared).items.first { $0.recordName == foreign }
        XCTAssertNil(item?.deferralReason, "the open decrypted it, which disproves the missing key")
        XCTAssertEqual(item?.state, .pending, "off Wi-Fi the pass the open started moves nothing")
        XCTAssertFalse(store.uploadCalls.contains(foreignID))

        try await openInViewer(prepared, foreignID, linkingWith: makeLoop())

        item = try await plan(prepared).items.first { $0.recordName == foreign }
        XCTAssertEqual(item?.state, .sourceDeleted, "back in the viewed tier, the next pass on Wi-Fi moves it")
        let entry = await indexEntries(prepared).first { $0.id == foreignID }
        XCTAssertEqual(entry?.photoLocation, .cloudKit)
    }

    func testViewedDeferralClearSurvivesSaveOfOlderPlanCopy() async throws {
        let otherKey = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let foreignID = UUID().uuidString
        let prepared = try await prepareAlbum(count: 1) { _, folder in
            try await self.writeForeignPhoto(foreignID, key: otherKey, into: folder)
        }
        let foreign = photoRecordName(foreignID)
        _ = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        let keyManager = try XCTUnwrap(albumManager.keyManager as? DemoKeyManager)
        try keyManager.save(key: otherKey, setNewKeyToCurrent: false)
        // A writer holding the plan from before the open: a pass part-way
        // through another item, say.
        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album, cloudKitAlbumID: prepared.albumID)
        let loaded = await planStore.load()
        let staleCopy = try XCTUnwrap(loaded)
        XCTAssertEqual(staleCopy.items.first { $0.recordName == foreign }?.deferralReason, .missingKey, "precondition")

        try await openInViewer(prepared, foreignID)
        try await planStore.save(staleCopy)

        let item = try await plan(prepared).items.first { $0.recordName == foreign }
        XCTAssertNil(item?.deferralReason, "a save of a copy loaded before the open does not defer it again")
        XCTAssertEqual(item?.priorityRequest?.reason, .viewed)
    }

    func testOpeningItemInAnotherAlbumKeepsItsDeferral() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let claimedID = prepared.mediaIDs[0]
        let claimed = photoRecordName(claimedID)
        store.confirmAlbumOverride[claimed] = .success("other-album")
        guard case .finished(let first) = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder) else {
            return XCTFail("expected finished")
        }
        XCTAssertEqual(first.deferredItems, [claimed: .recordInAnotherAlbum])
        let uploadsBefore = store.uploadCalls.count

        try await openInViewer(prepared, claimedID, linkingWith: makeLoop(isOnUnmeteredNetwork: { false }))

        let item = try await plan(prepared).items.first { $0.recordName == claimed }
        XCTAssertEqual(item?.deferralReason, .recordInAnotherAlbum, "decrypting it does not change who owns the record")
        XCTAssertEqual(item?.priorityRequest?.reason, .viewed)
        XCTAssertEqual(store.uploadCalls.count, uploadsBefore, "off Wi-Fi the pass the open started uploads nothing")
    }

    // MARK: - No cancel

    func testCancelIsUnavailableForLinkedAlbum() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let store = self.store!
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store },
                                               materializer: materializer)
        // A whole-album move of the linked folder, left by an older run.
        let wholeAlbumStore = MigrationPlanStore(album: prepared.album)
        let wholeAlbum = try MigrationPlan.album(prepared.album, items: try await plan(prepared).items,
                                                 cloudKitAlbumID: prepared.albumID)
        try await wholeAlbumStore.save(wholeAlbum)
        defer { Task { await wholeAlbumStore.delete() } }

        XCTAssertFalse(manager.requestCancel(plan: wholeAlbum), "the cancel is refused")
        await manager.cancel(plan: wholeAlbum)
        await manager.cancel(album: prepared.album)
        let rolledBack = await manager.rollBack(plan: wholeAlbum)
        XCTAssertFalse(rolledBack, "nor rolled back")

        let kept = await wholeAlbumStore.load()
        XCTAssertNotNil(kept, "the plan is kept")
        XCTAssertNil(kept?.cancelledAt, "and never stamped cancelled")
        let linkedPlan = try await plan(prepared)
        XCTAssertNil(linkedPlan.cancelledAt)

        // The user's start of an iCloud Drive album's move offers no cancel.
        let (album, _, _) = try await makeICloudDriveAlbum(count: 1)
        var acceptedDuringStep: [Bool] = []
        var cancelDuringStep: Bool?
        var stepManager: CloudKitMigrationManager?
        let step = makeAlbumStep { albumID, _ in
            self.touchedAlbumIDs.insert(albumID)
            guard let stepManager else { return }
            acceptedDuringStep = [stepManager.acceptsCancel, stepManager.progress.acceptsCancel]
            cancelDuringStep = stepManager.requestCancel(plan: try! MigrationPlan.album(album, items: []))
        }
        stepManager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in store },
                                               materializer: materializer,
                                               makeICloudDriveAlbumMigration: { _ in step })
        let started = await stepManager?.start(album: album, trigger: .user)

        XCTAssertEqual(started, true)
        XCTAssertEqual(acceptedDuringStep, [false, false], "neither the engine nor its progress offers a cancel")
        XCTAssertEqual(cancelDuringStep, false, "a cancel request is refused")
        XCTAssertEqual(stepManager?.state, .completed, "and the move finishes")
    }

    // MARK: - Conflicts

    func testConflictedFileMigratesCurrentVersionAndDiscardsOthers() async throws {
        let prepared = try await prepareAlbum(count: 2)
        let moving = prepared.mediaIDs[0]
        let failing = prepared.mediaIDs[1]
        let versions = FakeFileVersions()
        versions.store = store
        let spy = self.spy!
        versions.deletes = { spy.calls.map(\.recordName) }
        var conflictBytes: [String: Data] = [:]
        for id in prepared.mediaIDs {
            let version = scratch.appendingPathComponent("\(id)-conflict-version")
            let bytes = Data("another device's version of \(id)".utf8)
            try bytes.write(to: version)
            conflictBytes[id] = bytes
            versions.setConflictVersions([version], of: photoURL(prepared, id))
        }
        // The file at the URL as the upload reads it, once its key stamp is on.
        let movingURL = photoURL(prepared, moving)
        let currentBytes = LockedBox<Data?>(nil)
        let store = self.store!
        let movingUpload = MockCloudKitMediaStore.Call.upload(recordName: photoRecordName(moving))
        store.onUploadStarted = {
            guard store.callOrder.last == movingUpload else { return }
            currentBytes.mutate { $0 = try? Data(contentsOf: movingURL) }
        }
        // The other item's record does not verify.
        store.metadataToReturn = [otherDeviceRecord(prepared, mediaID: failing,
                                                    sizeBytes: try fileSize(photoURL(prepared, failing)) + 1)]

        let outcome = await makeLoop(fileVersions: versions).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let report) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        XCTAssertEqual(report.deleted, [photoRecordName(moving)], "a conflicted file is not a terminal failure")
        XCTAssertEqual(report.deferredItems, [:])
        let uploaded = try XCTUnwrap(store.uploadedBlobBytes[photoRecordName(moving)])
        XCTAssertEqual(uploaded, try XCTUnwrap(currentBytes.value), "the current version is what moved")
        XCTAssertNotEqual(uploaded, conflictBytes[moving])

        XCTAssertEqual(versions.resolutions.map(\.url.lastPathComponent), [photoURL(prepared, moving).lastPathComponent],
                       "only the item that verified has its conflict resolved")
        XCTAssertEqual(versions.unresolvedConflictVersionURLs(of: photoURL(prepared, moving)), [],
                       "its other versions are gone")
        let resolution = try XCTUnwrap(versions.resolutions.first)
        let verify = try XCTUnwrap(resolution.storeCallsSoFar.lastIndex(of: .fetchRecordMetadata(recordName: photoRecordName(moving))))
        XCTAssertGreaterThan(verify, try XCTUnwrap(resolution.storeCallsSoFar.lastIndex(of: .upload(recordName: photoRecordName(moving)))),
                             "the conflict is resolved after the record verified")
        XCTAssertFalse(resolution.deletesSoFar.contains(photoRecordName(moving)), "and before the file is deleted")
        XCTAssertTrue(spy.calls.contains { $0.recordName == photoRecordName(moving) })

        XCTAssertEqual(versions.unresolvedConflictVersionURLs(of: photoURL(prepared, failing)).count, 1,
                       "an item that failed keeps every version")
        XCTAssertTrue(ICloudPlaceholderName.isMaterialized(photoURL(prepared, failing)))

        #if os(macOS)
        // The resolution `NSFileVersion` does: another version of a file is gone
        // after it, and the current version is untouched. Only macOS can add a
        // version to a local file.
        let file = scratch.appendingPathComponent("versioned.\(MediaType.photo.encryptedFileExtension)")
        try Data("current".utf8).write(to: file)
        let otherContents = scratch.appendingPathComponent("other-contents")
        try Data("other".utf8).write(to: otherContents)
        _ = try NSFileVersion.addOfItem(at: file, withContentsOf: otherContents, options: [])
        XCTAssertEqual(NSFileVersion.otherVersionsOfItem(at: file)?.count, 1, "precondition: another version")
        try ICloudDriveFileVersions().resolveConflicts(keepingCurrentVersionOf: file)
        XCTAssertEqual(NSFileVersion.otherVersionsOfItem(at: file)?.count ?? 0, 0, "the other versions are gone")
        XCTAssertEqual(try Data(contentsOf: file), Data("current".utf8), "the current version is kept")
        #endif
    }

    // MARK: - Finishing an album

    private func folderExists(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.path)
    }

    /// A real encrypted photo an older build saves into the album's folder,
    /// which no plan item names.
    private func addOldBuildPhoto(_ prepared: Prepared) async throws -> String {
        let id = UUID().uuidString
        let backend = DiskMediaBackend()
        await backend.configure(for: prepared.album, albumManager: albumManager)
        _ = try await backend.save(
            media: try InteractableMedia(underlyingMedia: [
                CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
            ]),
            metadata: nil, progress: { _ in })
        return id
    }

    /// Runs a pass that tries everything, and returns what the finish at its end did.
    private func passAndFinish(_ prepared: Prepared,
                               file: StaticString = #filePath,
                               line: UInt = #line) async -> ICloudDriveAlbumFinish.Outcome? {
        let outcome = await makeLoop().runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        guard case .finished = outcome else {
            XCTFail("expected finished, got \(outcome)", file: file, line: line)
            return nil
        }
        return albumFinish.outcomes[prepared.albumID]
    }

    private func assertFolderKept(_ prepared: Prepared, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(folderExists(prepared.folder), "the folder stays", file: file, line: line)
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: prepared.folder, conflictVersions: { _ in [] }),
                       .present(ICloudDriveAlbumMarkerFile(albumID: prepared.albumID)), "with its marker",
                       file: file, line: line)
        XCTAssertTrue(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID),
                      "the plan stays", file: file, line: line)
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath,
                        "the link stays", file: file, line: line)
    }

    private func assertFinished(_ prepared: Prepared, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(folderExists(prepared.folder), "the folder is removed", file: file, line: line)
        XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID),
                       "the plan is deleted", file: file, line: line)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath,
                     "the link is dropped", file: file, line: line)
    }

    func testFolderRemovedOnlyWhenEmptyInEveryForm() async throws {
        let prepared = try await prepareAlbum(count: 2)
        folderContents.metadata = []
        let folder = prepared.folder

        // A real file, which no plan item names.
        let realFile = try await addOldBuildPhoto(prepared)
        var finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.notEmpty(entries: 1)), "a real file keeps the folder")
        XCTAssertEqual(mediaFiles(in: folder), [photoURL(prepared, realFile).lastPathComponent],
                       "the planned items moved; the real file is untouched")
        assertFolderKept(prepared)
        try FileManager.default.removeItem(at: photoURL(prepared, realFile))

        // A hidden file.
        let hidden = folder.appendingPathComponent(".left-by-another-app")
        try Data("hidden".utf8).write(to: hidden)
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.notEmpty(entries: 1)), "a hidden file keeps the folder")
        assertFolderKept(prepared)
        try FileManager.default.removeItem(at: hidden)

        // A placeholder only the metadata reports.
        let reportedID = UUID().uuidString
        folderContents.metadata = ["\(reportedID).\(MediaType.photo.encryptedFileExtension)"]
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.placeholdersReported(entries: 1)), "a placeholder not on disk keeps the folder")
        assertFolderKept(prepared)
        folderContents.metadata = []

        // Metadata that cannot be read.
        folderContents.metadata = nil
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.contentsUnknown), "a folder that cannot be confirmed empty stays")
        assertFolderKept(prepared)
        folderContents.metadata = []

        // A file that lands after the folder was listed, before the coordinated delete.
        let lateFile = folder.appendingPathComponent("\(UUID().uuidString).\(MediaType.photo.encryptedFileExtension)")
        folderContents.onMetadataRead = { try? Data("late".utf8).write(to: lateFile) }
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.changedBeforeRemoval), "the coordinated delete lists the folder again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateFile.path), "and keeps what arrived")
        assertFolderKept(prepared)
        folderContents.onMetadataRead = nil
        try FileManager.default.removeItem(at: lateFile)

        // An index component still on iCloud Drive, whose file this device no
        // longer lists.
        let indexStore = albumManager.mediaIndexStore(for: prepared.cloudKitAlbum)
        let strayID = UUID().uuidString
        try await indexStore.apply { entries in
            entries.append(MediaIndexEntry(id: strayID, hasPhotoComponent: true, hasVideoComponent: false,
                                           dateEncrypted: Date(), dateTaken: nil, subtypeRawValue: 0,
                                           photoLocation: .iCloudDrive))
        }
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.componentsOnICloudDrive(1)), "every component must be in CloudKit first")
        assertFolderKept(prepared)
        try await indexStore.apply { entries in entries.removeAll { $0.id == strayID } }

        // Nothing but the marker, in every form.
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .removed)
        assertFinished(prepared)
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder)),
                       "the marker went with the folder")
    }

    func testPlaceholderKeepsFolderAlive() async throws {
        let prepared = try await prepareAlbum(count: 1)
        let evictedID = UUID().uuidString
        let placeholderName = ".\(evictedID).\(MediaType.photo.encryptedFileExtension).icloud"

        // iCloud reports an evicted file this device's listing does not show.
        folderContents.metadata = [placeholderName]
        var finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.placeholdersReported(entries: 1)))
        assertFolderKept(prepared)
        XCTAssertTrue(folderWatches.isWatching(albumID: prepared.albumID), "the folder is still watched")

        // An evicted file's placeholder on disk.
        folderContents.metadata = []
        let placeholder = prepared.folder.appendingPathComponent(placeholderName)
        try Data().write(to: placeholder)
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.notEmpty(entries: 1)), "a placeholder on disk keeps the folder")
        assertFolderKept(prepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path))

        try FileManager.default.removeItem(at: placeholder)
        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .removed, "the folder goes once no placeholder is left")
        assertFinished(prepared)
    }

    func testFileAddedByOldBuildBeforeDoneIsMigrated() async throws {
        let prepared = try await prepareAlbum(count: 1)
        folderContents.metadata = []
        let source = try XCTUnwrap(changeSources.first, "the album step watches the folder")

        // An older build adds a file after the album step planned the folder.
        let addedID = try await addOldBuildPhoto(prepared)
        source.fire()
        let deadline = Date().addingTimeInterval(5)
        while await indexEntries(prepared).first(where: { $0.id == addedID })?.photoLocation != .iCloudDrive {
            guard Date() < deadline else { return XCTFail("timed out waiting until the watch indexed the added file") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let finish = await passAndFinish(prepared)

        XCTAssertEqual(finish, .kept(.notEmpty(entries: 1)), "the added file keeps the folder")
        XCTAssertTrue(ICloudPlaceholderName.isMaterialized(photoURL(prepared, addedID)), "and is not lost")
        assertFolderKept(prepared)

        // The next album step plans it, and its pass moves it and finishes.
        let loop = makeLoop()
        let step = makeAlbumStep { albumID, folder in _ = await loop.runMigrationPass(albumID: albumID, folder: folder) }
        let outcome = await step.run(folder: prepared.folder)

        XCTAssertEqual(outcome, .prepared(albumID: prepared.albumID))
        XCTAssertTrue(store.uploadCalls.contains(addedID), "the added file was uploaded")
        let entry = await indexEntries(prepared).first { $0.id == addedID }
        XCTAssertEqual(entry?.photoLocation, .cloudKit, "and is in CloudKit")
        XCTAssertEqual(albumFinish.outcomes[prepared.albumID], .removed)
        assertFinished(prepared)
    }

    func testDeferredItemKeepsFolder() async throws {
        let corruptID = UUID().uuidString
        let prepared = try await prepareAlbum(count: 1) { _, folder in
            try Data(repeating: 0xA5, count: 600)
                .write(to: folder.appendingPathComponent("\(corruptID).\(MediaType.photo.encryptedFileExtension)"))
        }
        folderContents.metadata = []

        var finish = await passAndFinish(prepared)

        XCTAssertEqual(finish, .kept(.deferredItems(1)), "a deferred item keeps the folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL(prepared, corruptID).path),
                      "its file is still there to read")
        XCTAssertEqual(mediaFiles(in: prepared.folder), [photoURL(prepared, corruptID).lastPathComponent])
        assertFolderKept(prepared)
        XCTAssertTrue(folderWatches.isWatching(albumID: prepared.albumID))
        let partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertTrue(partly, "the album is still partly on iCloud Drive")

        finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .kept(.deferredItems(1)), "on every later pass too")
        assertFolderKept(prepared)
    }

    func testDoneAlbumHasNoPlanAndNoFolderLink() async throws {
        let prepared = try await prepareAlbum(count: 2)
        folderContents.metadata = []
        var partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertTrue(partly, "precondition: an album mid-move is partly on iCloud Drive")
        XCTAssertTrue(ICloudDriveBlobMigration.hasPendingPlans())
        XCTAssertTrue(CloudKitMigrationManager.isMoveFromLinkedICloudDriveFolder(source: nil, destinationCloudKitAlbumID: prepared.albumID))

        let finish = await passAndFinish(prepared)

        XCTAssertEqual(finish, .removed)
        assertFinished(prepared)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MigrationPlanStore.iCloudDriveMigrationPlanURL(cloudKitAlbumID: prepared.albumID)
                .deletingLastPathComponent().path), "nothing is left of the plan")
        let entries = await indexEntries(prepared)
        XCTAssertEqual(entries.count, 2, "every item is still in the album")
        XCTAssertTrue(entries.allSatisfy { $0.photoLocation == .cloudKit }, "every component is in CloudKit")
        XCTAssertFalse(ICloudDriveBlobMigration.isRunning(albumID: prepared.albumID))
        XCTAssertNil(ICloudDriveBlobMigration.pauseReason(albumID: prepared.albumID))
        XCTAssertFalse(ICloudDriveBlobMigration.hasPendingPlans())
        let deferred = await ICloudDriveBlobMigration.deferredCount(for: prepared.cloudKitAlbum)
        XCTAssertEqual(deferred, 0)
        XCTAssertFalse(CloudKitMigrationManager.isMoveFromLinkedICloudDriveFolder(source: nil, destinationCloudKitAlbumID: prepared.albumID),
                       "the album's moves are no longer moves into a linked album")
        partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertFalse(partly, "the done album is fully in CloudKit")

        // The same as an album that was always a CloudKit album.
        let nativeID = UUID().uuidString
        touchedAlbumIDs.insert(nativeID)
        let native = Album(encryptedName: Album(name: "native-\(UUID().uuidString)", storageOption: .cloudKit,
                                                creationDate: Date(), key: key).encryptedPathComponent,
                           storageOption: .cloudKit, creationDate: Date(), key: key, albumID: nativeID)
        try CloudKitAlbumMarker(album: native, isHidden: false).write(albumID: nativeID)
        let nativePartly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(native, albumManager: albumManager)
        XCTAssertFalse(nativePartly)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath,
                       CloudKitAlbumMarker.read(albumID: nativeID)?.iCloudDriveFolderPath)
        XCTAssertEqual(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID),
                       MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: nativeID))

        let listed = albumManager.fetchAlbumsFromSources()
        XCTAssertTrue(listed.contains { $0.id == prepared.cloudKitAlbum.id }, "the album is listed")
        XCTAssertFalse(listed.contains { $0.storageOption == .icloud && $0.name == prepared.album.name },
                       "with no iCloud Drive album beside it")
    }

    func testWatchStopsAfterFolderRemoved() async throws {
        let prepared = try await prepareAlbum(count: 1)
        folderContents.metadata = []
        let source = try XCTUnwrap(changeSources.first)
        XCTAssertEqual(changeSources.count, 1)
        XCTAssertEqual(source.startedFolders.map(\.standardizedFileURL), [prepared.folder.standardizedFileURL],
                       "the album step watches the linked folder")
        XCTAssertTrue(source.isRunning)
        XCTAssertTrue(folderWatches.isWatching(albumID: prepared.albumID))

        let finish = await passAndFinish(prepared)

        XCTAssertEqual(finish, .removed)
        XCTAssertEqual(source.stopCount, 1, "the scanner's watch stopped with the folder")
        XCTAssertFalse(source.isRunning)
        XCTAssertFalse(folderWatches.isWatching(albumID: prepared.albumID))

        // Later runs watch nothing, for the folder or for its return.
        let step = makeAlbumStep(albumFolders: { [] })
        _ = await step.runEveryFolder()
        _ = await step.run(folder: prepared.folder)
        XCTAssertEqual(changeSources.count, 1, "no watch is started again")
        XCTAssertFalse(folderWatches.isWatching(albumID: prepared.albumID))
    }

    func testRecreatedFolderWithoutMarkerIsPlainICloudDriveAlbum() async throws {
        let prepared = try await prepareAlbum(count: 1)
        folderContents.metadata = []
        let finish = await passAndFinish(prepared)
        XCTAssertEqual(finish, .removed)

        // An older build saves into the album again, recreating its folder.
        try FileManager.default.createDirectory(at: prepared.folder, withIntermediateDirectories: true)
        let addedID = try await addOldBuildPhoto(prepared)
        XCTAssertTrue(ICloudPlaceholderName.isMaterialized(photoURL(prepared, addedID)))

        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: prepared.folder, conflictVersions: { _ in [] }),
                       .absent, "the recreated folder has no marker")
        let store = self.store!
        let walk = ICloudDriveAlbumFolderWalk(albumManager: albumManager, makeStore: { store },
                                              publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()),
                                              deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
                                              conflictVersions: { _ in [] },
                                              flipRegistry: ICloudDriveAlbumFlipRegistry())
        let walked = await walk.walk(folder: prepared.folder)
        XCTAssertEqual(walked.adoptionState, .noMarker, "the walk reads it as a plain iCloud Drive album")
        XCTAssertFalse(walked.changedAlbumMarker, "and links nothing to it")
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath)
        let listed = albumManager.fetchAlbumsFromSources()
        XCTAssertTrue(listed.contains { $0.storageOption == .icloud && $0.name == prepared.album.name },
                      "the album list shows it as an iCloud Drive album")
        XCTAssertTrue(listed.contains { $0.id == prepared.cloudKitAlbum.id }, "beside the CloudKit album")
        XCTAssertEqual(changeSources.count, 1, "nothing watched for the folder's return")
        XCTAssertFalse(folderWatches.isWatching(albumID: prepared.albumID))
    }

    func testLinkedFolderRemovedElsewhereIsFinishedOnNextRun() async throws {
        let prepared = try await prepareAlbum(count: 1)
        // A pass that moves everything but cannot confirm the folder empty.
        let first = await passAndFinish(prepared)
        XCTAssertEqual(first, .kept(.contentsUnknown))
        // The folder goes: another device finished the album, or this device
        // died after removing it.
        try FileManager.default.removeItem(at: prepared.folder)

        // A folder whose marker this device cannot read yet may be the album's
        // folder renamed: nothing is finished.
        let other = prepared.folder.deletingLastPathComponent().appendingPathComponent("renamed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let evictedMarker = ICloudPlaceholderName.placeholderURL(forMaterialized: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: other))
        try Data().write(to: evictedMarker)
        _ = await makeAlbumStep(albumFolders: { [other] }).runEveryFolder()
        XCTAssertTrue(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: prepared.albumID))
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: prepared.albumID)?.iCloudDriveFolderPath)
        XCTAssertTrue(folderWatches.isWatching(albumID: prepared.albumID))

        try FileManager.default.removeItem(at: other)
        _ = await makeAlbumStep(albumFolders: { [] }).runEveryFolder()

        assertFinished(prepared)
        XCTAssertFalse(folderWatches.isWatching(albumID: prepared.albumID), "its watch is stopped")
        let partly = await ICloudDriveAlbumFinish.isPartlyOnICloudDrive(prepared.cloudKitAlbum, albumManager: albumManager)
        XCTAssertFalse(partly)
        XCTAssertTrue(albumManager.fetchAlbumsFromSources().contains { $0.id == prepared.cloudKitAlbum.id },
                      "the album is still listed")
    }

    // MARK: - Scratch

    /// A background task run killed mid-video leaves its scratch directory, with plaintext,
    /// for no process to release. The launch cleanup removes it and keeps a
    /// directory a re-encryption in this process is using.
    func testScratchSweptAtLaunch() throws {
        let tmp = FileManager.default.temporaryDirectory
        let leftover = tmp.appendingPathComponent("\(MigrationReencryptScratch.directoryPrefix)\(UUID().uuidString)",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: 32).write(to: leftover.appendingPathComponent("plaintext.mov"))
        let inUse = try MigrationReencryptScratch.makeDirectory()
        defer {
            MigrationReencryptScratch.release(inUse)
            try? FileManager.default.removeItem(at: leftover)
        }

        TempFileAccess.cleanupTemporaryFiles()

        let remaining = ((try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(MigrationReencryptScratch.directoryPrefix) }
            .map { $0.standardizedFileURL.path }
        XCTAssertEqual(remaining, [inUse.standardizedFileURL.path],
                       "no migration-enc3 directory survives the launch but the one in use")
    }
}

/// A value shared with a `@Sendable` callback.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

/// The finish's metadata read for a folder in the substituted iCloud Drive
/// container, a plain directory iCloud does not track.
@MainActor
final class ICloudDriveAlbumFolderMetadataOverrideTests: XCTestCase {

    private var originalOverride: URL?
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = iCloudStorageModel.testContainerRootOverride
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("metadata-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        iCloudStorageModel.testContainerRootOverride = originalOverride
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAFolderInTheSubstitutedContainerReportsNoMetadata() async throws {
        let folder = root.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.encimage"))
        iCloudStorageModel.testContainerRootOverride = root

        let names = await ICloudDriveAlbumFolderDiskContents.queryMetadataNames(in: folder, timeout: 0.1)

        XCTAssertEqual(names, [], "the substituted container holds nothing iCloud reports beyond the disk")
    }

    func testOnlyFoldersInsideTheSubstitutedContainerAreCovered() {
        let root = URL(fileURLWithPath: "/tmp/UITestICloudDrive", isDirectory: true)

        XCTAssertTrue(ICloudDriveAlbumFolderDiskContents.isInSubstitutedContainer(
            root.appendingPathComponent("Trip", isDirectory: true), root: root))
        XCTAssertFalse(ICloudDriveAlbumFolderDiskContents.isInSubstitutedContainer(root, root: root),
                       "the container itself is not an album folder")
        XCTAssertFalse(ICloudDriveAlbumFolderDiskContents.isInSubstitutedContainer(
            URL(fileURLWithPath: "/tmp/UITestICloudDriveOther/Trip", isDirectory: true), root: root),
                       "a sibling whose path merely starts with the root's is outside it")
        XCTAssertFalse(ICloudDriveAlbumFolderDiskContents.isInSubstitutedContainer(
            URL(fileURLWithPath: "/tmp/Elsewhere/Trip", isDirectory: true), root: root))
        XCTAssertFalse(ICloudDriveAlbumFolderDiskContents.isInSubstitutedContainer(
            root.appendingPathComponent("Trip", isDirectory: true), root: nil),
                       "nothing is covered without a substituted container")
    }
}
