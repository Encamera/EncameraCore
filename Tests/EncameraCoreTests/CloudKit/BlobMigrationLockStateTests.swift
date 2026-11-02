//
//  BlobMigrationLockStateTests.swift
//  EncameraCoreTests
//
//  The blob migration while the phone is locked: keys come from the in-memory
//  cache and never from the keychain, a background task run with nothing held ends at once,
//  only ciphertext-only items move, and no re-encryption plaintext is written
//  without protected data.
//
//  The phone's lock state is the loop's `MigrationDeviceConditions.isUnlocked` seam and a
//  private notification center carrying `protectedDataWillBecomeUnavailable`.
//  Keychain reads go through a key manager that fails the test on any read once
//  armed. The iCloud Drive container is a scratch directory holding real
//  encrypted media, prepared by the real album step; the CloudKit store and the
//  iCloud download observation are fakes.
//

import CloudKit
import XCTest
@testable import EncameraCore

@MainActor
final class BlobMigrationLockStateTests: XCTestCase {

    private var containerRoot: URL!
    private var scratch: URL!
    private var key: PrivateKey!
    private var keyManager: KeychainReadSpy!
    private var albumManager: AlbumManager!
    private var store: MockCloudKitMediaStore!
    private var materializer: FakeICloudDriveMaterializer!
    private var keyCache: BlobMigrationKeyCache!
    private var notifications: NotificationCenter!
    private var touchedAlbumIDs: Set<String> = []
    private var cloudKitStorageWasEnabled = false
    private var debugLogWasCapturing = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        containerRoot = base.appendingPathComponent("blob-lock-state-\(UUID().uuidString)", isDirectory: true)
        scratch = base.appendingPathComponent("blob-lock-state-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot

        key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        keyManager = KeychainReadSpy(keys: [key])
        keyManager.currentKey = key
        albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        store = MockCloudKitMediaStore()
        store.reflectUploadsInMetadata = true
        materializer = FakeICloudDriveMaterializer()
        keyCache = BlobMigrationKeyCache()
        notifications = NotificationCenter()
        cloudKitStorageWasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        debugLogWasCapturing = DebugLogBuffer.shared.isCapturing
        MigrationReencryptScratch.sweepLeftovers()
    }

    override func tearDownWithError() throws {
        keyManager.armed = false
        LocalToCloudKitStep.afterReencryptWriteForTesting = nil
        for albumID in touchedAlbumIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        }
        touchedAlbumIDs = []
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: cloudKitStorageWasEnabled)
        DebugLogBuffer.shared.setCapturing(debugLogWasCapturing)
        iCloudStorageModel.testContainerRootOverride = nil
        ICloudPlaceholderName.testEvictedURLs = nil
        try? FileManager.default.removeItem(at: containerRoot)
        try? FileManager.default.removeItem(at: scratch)
        try? MediaIndexStore.clearAllIndexes()
        albumManager = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A key manager that fails the test on any keychain read while armed.
    private final class KeychainReadSpy: DemoKeyManager {
        var armed = false
        private(set) var reads: [String] = []

        private func read(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
            guard armed else { return true }
            reads.append(name)
            XCTFail("keychain read while locked: \(name)", file: file, line: line)
            return false
        }

        override func storedKeys() throws -> [PrivateKey] {
            guard read("storedKeys") else { throw KeyManagerError.notFound }
            return try super.storedKeys()
        }

        override func keyWith(uuid: UUID) -> PrivateKey? {
            guard read("keyWith(uuid:)") else { return nil }
            return super.keyWith(uuid: uuid)
        }

        override func getPasswordHash() throws -> Data {
            guard read("getPasswordHash") else { throw KeyManagerError.notFound }
            return try super.getPasswordHash()
        }

        override func retrieveKeyPassphrases() throws -> [KeyPassphrase] {
            guard read("retrieveKeyPassphrases") else { throw KeyManagerError.notFound }
            return try super.retrieveKeyPassphrases()
        }

        override func passwordExists() -> Bool {
            guard read("passwordExists") else { return false }
            return super.passwordExists()
        }

        override func credentialSnapshot() -> KeychainCredentialSnapshot {
            _ = read("credentialSnapshot")
            return super.credentialSnapshot()
        }
    }

    /// The phone's lock state as the loop sees it.
    private final class Phone {
        var isUnlocked = true
        var isInBackground = false
    }

    /// Records every `migration-enc3-*` entry that appears in the temporary
    /// directory, where re-encryption scratch directories are made.
    private final class ScratchWatcher {
        private let root = FileManager.default.temporaryDirectory
        private let queue = DispatchQueue(label: "scratch-watcher", qos: .userInteractive)
        private var source: DispatchSourceFileSystemObject?
        private var descriptor: Int32 = -1
        private let lock = NSLock()
        private var _seen: Set<String> = []

        var seen: Set<String> { lock.withLock { _seen } }

        func start() {
            descriptor = open(root.path, O_EVTONLY)
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link],
                                                                   queue: queue)
            source.setEventHandler { [weak self] in self?.look() }
            source.setCancelHandler { [descriptor] in close(descriptor) }
            self.source = source
            source.resume()
            look()
        }

        func look() {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasPrefix(MigrationReencryptScratch.directoryPrefix) }
            lock.withLock { _seen.formUnion(names) }
        }

        func stop() {
            look()
            source?.cancel()
            source = nil
        }

        /// The scratch directories in the temporary directory right now.
        func present() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasPrefix(MigrationReencryptScratch.directoryPrefix) }
        }
    }

    private struct NotPrepared: Error {}

    private struct Prepared {
        let albumID: String
        let folder: URL
        let album: Album
        let photoIDs: [String]
        let videoID: String?
    }

    /// An iCloud Drive album holding `photos` real encrypted photos and, when
    /// `video` is set, one legacy ENC2 video over the chunking threshold, run
    /// through the album step.
    private func prepareAlbum(photos: Int, video: Bool) async throws -> Prepared {
        let album = Album(name: "lock-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: key)
        let model = iCloudStorageModel(album: album)
        try model.initializeDirectories()
        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        var ids: [String] = []
        for _ in 0..<photos {
            let id = UUID().uuidString
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
                ]),
                metadata: nil, progress: { _ in })
            ids.append(id)
        }
        var videoID: String?
        if video {
            let id = UUID().uuidString
            var plaintext = Data(count: SeekableEncryptedFormat.threshold + 1024 * 1024)
            plaintext.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            let plaintextURL = scratch.appendingPathComponent("\(id).mov")
            try plaintext.write(to: plaintextURL)
            let handler = SecretFileHandlerV2(keyBytes: key.keyBytes,
                                              source: CleartextMedia(source: plaintextURL, mediaType: .video, id: id),
                                              targetURL: model.baseURL.appendingPathComponent("\(id).\(MediaType.video.encryptedFileExtension)"))
            _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
            try FileManager.default.removeItem(at: plaintextURL)
            videoID = id
        }

        let store = self.store!
        let step = ICloudDriveAlbumMigration(albumManager: albumManager,
                                             makeStore: { store },
                                             materializer: materializer,
                                             publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()),
                                             deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
                                             conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                               hasICloudDrive: { true }),
                                             conflictVersions: { _ in [] },
                                             flipRegistry: ICloudDriveAlbumFlipRegistry(),
                                             zoneWalkRequests: CloudKitZoneWalkRequests(defaults: makeIsolatedDefaults()))
        let outcome = await step.run(folder: model.baseURL)
        guard case .prepared(let albumID) = outcome else {
            XCTFail("precondition: the album step prepared the album, got \(outcome)")
            throw NotPrepared()
        }
        touchedAlbumIDs.insert(albumID)
        return Prepared(albumID: albumID, folder: model.baseURL, album: album, photoIDs: ids, videoID: videoID)
    }

    private func makeLoop(_ phone: Phone, _ prepared: Prepared,
                          deviceState: (@MainActor () -> BlobMigrationDeviceState)? = nil) -> ICloudDriveBlobMigration {
        let store = self.store!
        let delete = ICloudDriveVerifiedDelete(store: store,
                                               markerConflictVersions: { _ in [] })
        let albumID = prepared.albumID
        let folder = prepared.folder
        return ICloudDriveBlobMigration(albumManager: albumManager,
                                        makeStore: { store },
                                        materializer: materializer,
                                        makeVerifiedDelete: { _ in delete },
                                        conditions: .init(isUnlocked: { phone.isUnlocked }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                          hasICloudDrive: { true },
                                                          isInBackground: { phone.isInBackground }),
                                        deviceState: deviceState,
                                        markerConflictVersions: { _ in [] },
                                        keyCache: keyCache,
                                        notificationCenter: notifications,
                                        linkedFolder: { $0 == albumID ? folder : nil })
    }

    /// Locks the phone as a background task run that resumed a suspended process
    /// finds it: the keys read while unlocked are held, the keychain is locked.
    private func lockWithKeysHeld(_ phone: Phone) {
        keyCache.refreshKeysFromKeychain(using: albumManager)
        phone.isUnlocked = false
        phone.isInBackground = true
        keyManager.armed = true
    }

    private func photoRecordName(_ mediaID: String) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: .photo)
    }

    private func videoRecordName(_ mediaID: String) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: .video)
    }

    private func fileURL(_ prepared: Prepared, _ mediaID: String, _ type: MediaType) -> URL {
        prepared.folder.appendingPathComponent("\(mediaID).\(type.encryptedFileExtension)")
    }

    private func planURL(_ prepared: Prepared) -> URL {
        MigrationPlanStore.iCloudDriveMigrationPlanURL(cloudKitAlbumID: prepared.albumID)
    }

    private func plan(_ prepared: Prepared) async throws -> MigrationPlan {
        let loaded = await MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album,
                                              cloudKitAlbumID: prepared.albumID).load()
        return try XCTUnwrap(loaded)
    }

    private func state(of recordName: String, in plan: MigrationPlan) -> MigrationItemState? {
        plan.items.first { $0.recordName == recordName }?.state
    }

    private func storeCalls(for recordName: String) -> [MockCloudKitMediaStore.Call] {
        store.callOrder.filter {
            switch $0 {
            case .upload(let name), .fetchRecordMetadata(let name), .confirmAlbum(let name): return name == recordName
            default: return false
            }
        }
    }

    // MARK: - Tests

    func testLockedBackgroundTaskRunWithKeysProcessesOnlyCiphertextOnlyItems() async throws {
        let prepared = try await prepareAlbum(photos: 2, video: true)
        let videoID = try XCTUnwrap(prepared.videoID)
        let phone = Phone()
        lockWithKeysHeld(phone)
        let watcher = ScratchWatcher()
        watcher.start()

        let report = await makeLoop(phone, prepared).runBackgroundTaskPasses()

        watcher.stop()
        XCTAssertTrue(report.keysInMemory)
        XCTAssertFalse(report.isUnlocked)
        guard case .finished(let pass)? = report.outcomes[prepared.albumID] else {
            return XCTFail("expected a finished pass, got \(String(describing: report.outcomes[prepared.albumID]))")
        }
        XCTAssertEqual(Set(pass.deleted), Set(prepared.photoIDs.map(photoRecordName)),
                       "every ciphertext-only item moved while locked")
        XCTAssertEqual(Set(store.uploadCalls), Set(prepared.photoIDs), "the encrypting item was never uploaded")
        XCTAssertEqual(storeCalls(for: videoRecordName(videoID)), [], "the encrypting item was never started")
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: videoRecordName(videoID), in: plan), .pending, "it stays queued")
        XCTAssertTrue(ICloudPlaceholderName.existsInAnyForm(fileURL(prepared, videoID, .video)))
        XCTAssertEqual(keyManager.reads, [], "no keychain read in the locked background task run")
        XCTAssertEqual(watcher.seen, [], "no re-encryption scratch while locked")
    }

    func testColdBackgroundTaskRunWithNoKeysExitsWithoutTouchingQueueOrKeychain() async throws {
        let prepared = try await prepareAlbum(photos: 2, video: false)
        let planBytes = try Data(contentsOf: planURL(prepared))
        let planDate = try FileManager.default.attributesOfItem(atPath: planURL(prepared).path)[.modificationDate] as? Date
        let storeCallsBefore = store.callOrder.count
        let materializeCallsBefore = materializer.requestedBatches.count
        let phone = Phone()
        phone.isUnlocked = false
        phone.isInBackground = true
        keyManager.armed = true

        let report = await makeLoop(phone, prepared).runBackgroundTaskPasses()

        XCTAssertFalse(report.keysInMemory)
        XCTAssertEqual(report.outcomes, [:], "no pass ran")
        XCTAssertEqual(keyManager.reads, [], "the keychain was never read")
        XCTAssertEqual(try Data(contentsOf: planURL(prepared)), planBytes, "the plan file is unchanged")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: planURL(prepared).path)[.modificationDate] as? Date,
                       planDate, "and was not rewritten")
        XCTAssertEqual(store.callOrder.count, storeCallsBefore, "CloudKit was not reached")
        XCTAssertEqual(materializer.requestedBatches.count, materializeCallsBefore, "nothing was downloaded")
        for mediaID in prepared.photoIDs {
            XCTAssertTrue(ICloudPlaceholderName.isMaterialized(fileURL(prepared, mediaID, .photo)))
        }

        // A pass started directly behaves the same.
        let outcome = await makeLoop(phone, prepared).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)
        XCTAssertEqual(outcome, .stopped(.locked, .init()))
        XCTAssertEqual(keyManager.reads, [])
        XCTAssertEqual(try Data(contentsOf: planURL(prepared)), planBytes)
    }

    func testEncryptingItemNeverStartsWithoutProtectedData() async throws {
        let prepared = try await prepareAlbum(photos: 1, video: true)
        let videoID = try XCTUnwrap(prepared.videoID)
        let phone = Phone()
        lockWithKeysHeld(phone)
        let watcher = ScratchWatcher()
        watcher.start()

        // The ordering is told the phone is unlocked, so it offers the encrypting
        // item: only the loop's own protected-data check stands in the way.
        let report = await makeLoop(phone, prepared, deviceState: { .unlocked }).runBackgroundTaskPasses()

        watcher.stop()
        guard case .finished(let pass)? = report.outcomes[prepared.albumID] else {
            return XCTFail("expected a finished pass, got \(String(describing: report.outcomes[prepared.albumID]))")
        }
        XCTAssertEqual(pass.waitingForUnlock, [videoRecordName(videoID)], "the encrypting item waited for unlock")
        XCTAssertEqual(pass.deleted, [photoRecordName(prepared.photoIDs[0])], "the other item still moved")
        XCTAssertEqual(storeCalls(for: videoRecordName(videoID)), [], "the encrypting item never started")
        XCTAssertEqual(watcher.seen, [], "no migration-enc3 scratch was created while protected data was unavailable")
        XCTAssertEqual(watcher.present(), [])
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: videoRecordName(videoID), in: plan), .pending)
        XCTAssertEqual(keyManager.reads, [])
    }

    func testLockMidItemRemovesScratchAndRequeues() async throws {
        let prepared = try await prepareAlbum(photos: 1, video: true)
        let videoID = try XCTUnwrap(prepared.videoID)
        let phone = Phone()
        let watcher = ScratchWatcher()
        watcher.start()
        let notifications = self.notifications!
        let keyManager = self.keyManager!
        var scratchAtLock: URL?
        var plaintextOnDiskAtLock = false
        LocalToCloudKitStep.afterReencryptWriteForTesting = { destination in
            // The phone locks with the re-encryption under way.
            MainActor.assumeIsolated {
                scratchAtLock = destination.deletingLastPathComponent()
                plaintextOnDiskAtLock = FileManager.default.fileExists(
                    atPath: destination.deletingLastPathComponent().appendingPathComponent("\(videoID).plain").path)
                phone.isUnlocked = false
                keyManager.armed = true
                notifications.post(name: AppLifecycleNotification.protectedDataWillBecomeUnavailable, object: nil)
            }
        }

        let outcome = await makeLoop(phone, prepared).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        watcher.stop()
        guard case .finished(let pass) = outcome else { return XCTFail("expected finished, got \(outcome)") }
        let scratch = try XCTUnwrap(scratchAtLock, "precondition: the encrypting item ran first and reached its re-encryption")
        XCTAssertTrue(plaintextOnDiskAtLock, "precondition: plaintext was on disk when the phone locked")
        XCTAssertTrue(watcher.seen.contains(scratch.lastPathComponent), "precondition: the watcher saw the scratch directory")
        XCTAssertEqual(pass.requeued, [videoRecordName(videoID)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "the scratch directory was removed")
        XCTAssertEqual(watcher.present(), [], "no scratch directory is left")
        XCTAssertFalse(store.uploadCalls.contains(videoID), "the abandoned item was not uploaded")
        let plan = try await plan(prepared)
        XCTAssertEqual(state(of: videoRecordName(videoID), in: plan), .pending, "it is pending again")
        XCTAssertNil(plan.items.first { $0.recordName == videoRecordName(videoID) }?.lastError)
        XCTAssertTrue(ICloudPlaceholderName.isMaterialized(fileURL(prepared, videoID, .video)), "its file is kept")
        XCTAssertEqual(pass.deleted, [photoRecordName(prepared.photoIDs[0])],
                       "the ciphertext-only item still moved after the lock")
        XCTAssertEqual(keyManager.reads, [], "and without a keychain read")
    }

    func testUnlockMakesEncryptingItemsEligibleFirst() async throws {
        let prepared = try await prepareAlbum(photos: 2, video: true)
        let videoID = try XCTUnwrap(prepared.videoID)
        let failing = prepared.photoIDs[1]
        store.uploadFailures[photoRecordName(failing)] = NSError(domain: "test", code: 1)
        let phone = Phone()
        lockWithKeysHeld(phone)

        let locked = await makeLoop(phone, prepared).runBackgroundTaskPasses()

        guard case .finished(let lockedPass)? = locked.outcomes[prepared.albumID] else {
            return XCTFail("expected a finished pass, got \(String(describing: locked.outcomes[prepared.albumID]))")
        }
        XCTAssertEqual(lockedPass.failed, [photoRecordName(failing)], "precondition: a ciphertext-only item is left")
        XCTAssertFalse(store.uploadCalls.contains(videoID), "precondition: the encrypting item waited")
        store.uploadFailures = [:]
        let uploadsBefore = store.uploadCalls.count

        keyManager.armed = false
        phone.isUnlocked = true
        phone.isInBackground = false
        let unlocked = await makeLoop(phone, prepared).runMigrationPass(albumID: prepared.albumID, folder: prepared.folder)

        guard case .finished(let pass) = unlocked else { return XCTFail("expected finished, got \(unlocked)") }
        XCTAssertEqual(Array(store.uploadCalls.dropFirst(uploadsBefore)), [videoID, failing],
                       "on unlock the encrypting item goes ahead of the ciphertext-only one")
        XCTAssertEqual(Set(pass.deleted), [videoRecordName(videoID), photoRecordName(failing)])
    }

    /// A user action, then a viewed item, run ahead of everything else, and a
    /// viewed ciphertext-only item runs while locked; a viewed encrypting item
    /// still waits for unlock.
    func testUserActionThenViewedRunFirstWhileLocked() async throws {
        let prepared = try await prepareAlbum(photos: 3, video: true)
        let videoID = try XCTUnwrap(prepared.videoID)
        let unrequested = prepared.photoIDs[0]
        let acted = prepared.photoIDs[1]
        let viewed = prepared.photoIDs[2]
        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: prepared.album, cloudKitAlbumID: prepared.albumID)
        let items = try await plan(prepared).items
        let earlier = Date(timeIntervalSinceNow: -60)
        try await planStore.prioritize(items.filter { $0.mediaID == viewed || $0.mediaID == videoID },
                                       reason: .viewed, at: earlier)
        try await planStore.prioritize(items.filter { $0.mediaID == acted }, reason: .userAction)
        let phone = Phone()
        lockWithKeysHeld(phone)

        let report = await makeLoop(phone, prepared).runBackgroundTaskPasses()

        guard case .finished? = report.outcomes[prepared.albumID] else {
            return XCTFail("expected a finished pass, got \(String(describing: report.outcomes[prepared.albumID]))")
        }
        XCTAssertEqual(store.uploadCalls, [acted, viewed, unrequested],
                       "the user action first, then the viewed item, then the rest")
        XCTAssertFalse(store.uploadCalls.contains(videoID), "a viewed encrypting item still waits for unlock")
        XCTAssertEqual(keyManager.reads, [], "no keychain read in the locked slice")
    }

    func testBackgroundTaskRunLogRecordsKeysInMemory() async throws {
        let prepared = try await prepareAlbum(photos: 1, video: false)
        DebugLogBuffer.shared.setCapturing(true)
        DebugLogBuffer.shared.clear()
        let phone = Phone()
        phone.isUnlocked = false
        phone.isInBackground = true

        let cold = await makeLoop(phone, prepared).runBackgroundTaskPasses()

        XCTAssertFalse(cold.keysInMemory)
        let coldLines = DebugLogBuffer.shared.snapshot(newestFirst: false).map(\.message)
        XCTAssertTrue(coldLines.contains { $0.hasPrefix("background task run start keysInMemory=false") },
                      "the debug log records a background task run with no keys: \(coldLines)")

        DebugLogBuffer.shared.clear()
        lockWithKeysHeld(phone)
        let resumed = await makeLoop(phone, prepared).runBackgroundTaskPasses()

        XCTAssertTrue(resumed.keysInMemory)
        let resumedLines = DebugLogBuffer.shared.snapshot(newestFirst: false).map(\.message)
        XCTAssertTrue(resumedLines.contains { $0.hasPrefix("background task run start keysInMemory=true") },
                      "the debug log records a background task run with keys: \(resumedLines)")
    }

    func testDownloadAheadRespectsFreeSpaceCap() async throws {
        let prepared = try await prepareAlbum(photos: 4, video: false)
        let urls = prepared.photoIDs.map { fileURL(prepared, $0, .photo) }
        ICloudPlaceholderName.testEvictedURLs = Set(urls.map(\.standardizedFileURL))
        keyCache.refreshKeysFromKeychain(using: albumManager)
        let plan = try await plan(prepared)
        let seed = BlobMigrationOrder.deviceSeed(deviceID: "download-ahead-device")
        let next = BlobMigrationOrder.next(items: plan.items, deviceState: .locked, seed: seed)
        let sizes = next.map(\.sizeBytes)
        XCTAssertTrue(sizes.allSatisfy { $0 > 0 }, "precondition: the plan knows each file's size")
        let albumID = prepared.albumID
        let folder = prepared.folder
        var requested: [URL] = []
        func downloadAhead(freeBytes: Int64?) -> ICloudDriveDownloadAhead {
            ICloudDriveDownloadAhead(keyCache: keyCache,
                                     freeSpace: FixedDeviceFreeSpace(freeBytes),
                                     isOnUnmeteredNetwork: { true },
                                     maxFiles: { 10 },
                                     startDownloading: { requested.append($0) },
                                     linkedFolder: { $0 == albumID ? folder : nil },
                                     seed: seed)
        }

        // Room for the first two files after the reserve, not the third.
        let room = ICloudDriveDownloadAhead.reservedBytes + sizes[0] + sizes[1] + sizes[2] / 2
        let first = await downloadAhead(freeBytes: room).requestNextBatchForHeldAlbums()

        let expected = next.prefix(2).map { fileURL(prepared, $0.mediaID, .photo) }
        XCTAssertEqual(requested, expected, "the batch stops at the first file that does not fit")
        XCTAssertEqual(first[albumID], expected)

        requested = []
        await downloadAhead(freeBytes: ICloudDriveDownloadAhead.reservedBytes).requestNextBatchForHeldAlbums()
        XCTAssertEqual(requested, [], "nothing beyond the reserve")

        requested = []
        await downloadAhead(freeBytes: nil).requestNextBatchForHeldAlbums()
        XCTAssertEqual(requested, [], "nothing while free space is unknown")

        requested = []
        await downloadAhead(freeBytes: Int64.max / 2).requestNextBatchForHeldAlbums()
        XCTAssertEqual(Set(requested), Set(urls), "every evicted file fits when space allows")
    }

    func testNoBatchOffWiFi() async throws {
        let prepared = try await prepareAlbum(photos: 2, video: false)
        let urls = prepared.photoIDs.map { fileURL(prepared, $0, .photo) }
        ICloudPlaceholderName.testEvictedURLs = Set(urls.map(\.standardizedFileURL))
        keyCache.refreshKeysFromKeychain(using: albumManager)
        let albumID = prepared.albumID
        let folder = prepared.folder
        var requested: [URL] = []
        func downloadAhead(onWiFi: Bool) -> ICloudDriveDownloadAhead {
            ICloudDriveDownloadAhead(keyCache: keyCache,
                                     freeSpace: FixedDeviceFreeSpace(Int64.max / 2),
                                     isOnUnmeteredNetwork: { onWiFi },
                                     maxFiles: { 10 },
                                     startDownloading: { requested.append($0) },
                                     linkedFolder: { $0 == albumID ? folder : nil })
        }

        let offWiFi = await downloadAhead(onWiFi: false).requestNextBatchForHeldAlbums()
        XCTAssertEqual(requested, [], "nothing is requested off Wi-Fi")
        XCTAssertEqual(offWiFi, [:])

        await downloadAhead(onWiFi: true).requestNextBatchForHeldAlbums()
        XCTAssertEqual(Set(requested), Set(urls), "on Wi-Fi the batch is requested")
    }
}
