//
//  ICloudDriveAlbumMigrationTests.swift
//  EncameraCoreTests
//
//  The per-album step that gives an iCloud Drive album its CloudKit album: which
//  album id it lands on, the order of the record save and the marker write, what
//  it leaves alone, and the plan it writes.
//
//  The iCloud Drive container is a scratch directory (`testContainerRootOverride`)
//  holding real encrypted media, and the album list is the real `AlbumManager`.
//  The CloudKit store and the iCloud download observation are fakes.
//

import Combine
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import EncameraCore

@MainActor
final class ICloudDriveAlbumMigrationTests: XCTestCase {

    private var containerRoot: URL!
    private var scratch: URL!
    private var key: PrivateKey!
    private var albumManager: AlbumManager!
    private var store: MockCloudKitMediaStore!
    private var publishRegistry: CloudKitAlbumPublishRegistry!
    private var deleteQueue: CloudKitAlbumDeleteQueue!
    private var downloads: [URL] = []
    private var touchedAlbumIDs: Set<String> = []
    private var zoneWalkRequests: CloudKitZoneWalkRequests!
    private var storesMade = 0
    private var blobMigrationStarts: [BlobMigrationStart] = []

    private struct BlobMigrationStart: Hashable {
        let albumID: String
        let folder: URL
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        containerRoot = base.appendingPathComponent("icloud-album-migration-\(UUID().uuidString)", isDirectory: true)
        scratch = base.appendingPathComponent("icloud-album-migration-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot

        key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        store = MockCloudKitMediaStore()
        publishRegistry = CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults())
        deleteQueue = CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults())
        downloads = []
        zoneWalkRequests = CloudKitZoneWalkRequests(defaults: makeIsolatedDefaults())
        storesMade = 0
        blobMigrationStarts = []
    }

    override func tearDownWithError() throws {
        for albumID in touchedAlbumIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            MigrationPlanStore.removeICloudDriveMigrationPlan(cloudKitAlbumID: albumID)
        }
        touchedAlbumIDs = []
        iCloudStorageModel.testContainerRootOverride = nil
        try? FileManager.default.removeItem(at: containerRoot)
        try? FileManager.default.removeItem(at: scratch)
        try? MediaIndexStore.clearAllIndexes()
        albumManager = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private struct DriveAlbum {
        let album: Album
        let folder: URL
        let mediaIDs: [String]
    }

    /// An iCloud Drive album holding `count` real encrypted photos.
    private func makeDriveAlbum(count: Int = 2) async throws -> DriveAlbum {
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
        return DriveAlbum(album: album, folder: model.baseURL, mediaIDs: ids)
    }

    /// The `EncAlbum` another device saved for `album` under `albumID`.
    private func record(albumID: String, for album: Album,
                        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CloudKitAlbumMetadata {
        touchedAlbumIDs.insert(albumID)
        let encName = Album.cloudKitTwin(of: album, albumID: albumID).encryptedPathComponent
        return CloudKitAlbumMetadata(albumID: albumID, encName: encName, createdAt: createdAt,
                                     isHidden: false, schemaVersion: 1,
                                     keyFingerprint: key.keyFingerprint, recordChangeTag: "tag")
    }

    private func makeMigration(conditions: ICloudDriveAlbumMigration.MigrationDeviceConditions = .init(isUnlocked: { true },
                                                                                       hasNetwork: { true },
                                                                                       isOnUnmeteredNetwork: { true }),
                               conflictVersions: @escaping (URL) -> [URL] = { _ in [] },
                               writeMarkerFile: ((ICloudDriveAlbumMarkerFile, URL) throws -> Void)? = nil,
                               makeVerifiedDelete: ((CloudKitMediaStoring) -> ICloudDriveComponentDeleting)? = nil,
                               flipRegistry: ICloudDriveAlbumFlipRegistry = ICloudDriveAlbumFlipRegistry(),
                               albumFolders: (() -> [URL])? = nil,
                               startBlobMigration: (@MainActor (String, URL) async -> Void)? = nil) -> ICloudDriveAlbumMigration {
        let store = self.store!
        return ICloudDriveAlbumMigration(albumManager: albumManager,
                                         makeStore: { [unowned self] in
                                             self.storesMade += 1
                                             return store
                                         },
                                         materializer: FakeICloudDriveMaterializer(),
                                         publishRegistry: publishRegistry,
                                         deleteQueue: deleteQueue,
                                         conditions: conditions,
                                         requestMarkerDownload: { [unowned self] in self.downloads.append($0) },
                                         conflictVersions: conflictVersions,
                                         writeMarkerFile: writeMarkerFile ?? { try $0.write(toAlbumDirectory: $1) },
                                         makeVerifiedDelete: makeVerifiedDelete ?? { ICloudDriveVerifiedDelete(store: $0) },
                                         flipRegistry: flipRegistry,
                                         zoneWalkRequests: zoneWalkRequests,
                                         albumFolders: albumFolders,
                                         startBlobMigration: startBlobMigration ?? { [unowned self] albumID, folder in
                                             self.blobMigrationStarts.append(BlobMigrationStart(albumID: albumID, folder: folder))
                                         })
    }

    private func run(_ drive: DriveAlbum, _ migration: ICloudDriveAlbumMigration? = nil) async -> ICloudDriveAlbumMigration.AlbumMigrationRunOutcome {
        let outcome = await (migration ?? makeMigration()).run(folder: drive.folder)
        if case .prepared(let albumID) = outcome { touchedAlbumIDs.insert(albumID) }
        return outcome
    }

    private func markerFile(in drive: DriveAlbum) -> ICloudDriveAlbumMarkerFile.ReadResult {
        ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: drive.folder, conflictVersions: { _ in [] })
    }

    private func plan(_ drive: DriveAlbum, albumID: String) async -> MigrationPlan? {
        await MigrationPlanStore(iCloudDriveMigrationFrom: drive.album, cloudKitAlbumID: albumID).load()
    }

    /// Every file under the folder other than the marker, with its bytes.
    private func mediaSnapshot(_ drive: DriveAlbum) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: drive.folder, includingPropertiesForKeys: nil)
            where !ICloudDriveAlbumMarkerFile.isMarkerFile(url) {
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }

    private var serverAlbumCalls: [MockCloudKitMediaStore.Call] {
        store.callOrder.filter {
            switch $0 {
            case .saveAlbum, .fetchAllAlbums, .fetchAlbum, .deleteAlbum: return true
            default: return false
            }
        }
    }

    private func assertNothingWritten(_ drive: DriveAlbum, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(store.savedAlbumCalls.isEmpty, "no album record saved", file: file, line: line)
        XCTAssertTrue(store.uploadCalls.isEmpty, "no media record written", file: file, line: line)
        XCTAssertTrue(CloudKitAlbumMarker.all().isEmpty, "no album.json written", file: file, line: line)
        let planDirectory = MigrationPlanStore.iCloudDriveMigrationDirectoryURL()
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: planDirectory.path)) ?? []).isEmpty,
                      "no plan written", file: file, line: line)
    }

    /// The album as an iCloud Drive album only, as the album list shows it.
    private func assertListedAsICloudDriveOnly(_ drive: DriveAlbum, file: StaticString = #filePath, line: UInt = #line) {
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertTrue(albums.contains { $0.storageOption == .icloud && $0.name == drive.album.name },
                      "the folder is listed", file: file, line: line)
        XCTAssertFalse(albums.contains { $0.storageOption == .cloudKit }, "no CloudKit album is listed",
                       file: file, line: line)
    }

    // MARK: - Album id

    func testAdoptsAlbumIDFromExistingMarkerFile() async throws {
        let drive = try await makeDriveAlbum()
        let albumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: drive.folder)
        store.seedAlbum(record(albumID: albumID, for: drive.album))
        // A server album with the same name and key under another id: name
        // matching must not run when the folder already names its album.
        let sameName = UUID().uuidString
        store.seedAlbum(record(albumID: sameName, for: drive.album, createdAt: Date(timeIntervalSince1970: 1)))

        let outcome = await run(drive)

        XCTAssertEqual(outcome, .prepared(albumID: albumID))
        XCTAssertEqual(serverAlbumCalls, [.fetchAlbum(albumID: albumID)], "fetched by id only; nothing saved or listed")
        XCTAssertEqual(markerFile(in: drive), .present(.init(albumID: albumID)))
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(marker.dirty, false, "adopting writes no change to the record")
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       drive.folder.standardizedFileURL)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: sameName))
        XCTAssertTrue(publishRegistry.isPublished(albumID))

        let loaded = await plan(drive, albumID: albumID)
        let plan = try XCTUnwrap(loaded)
        XCTAssertEqual(plan.destination.cloudKitAlbumID, albumID)

        // A later run reads the marker again and still lands on it, without a fetch.
        let again = await run(drive)
        XCTAssertEqual(again, .prepared(albumID: albumID))
        XCTAssertEqual(serverAlbumCalls, [.fetchAlbum(albumID: albumID)])
        XCTAssertTrue(store.savedAlbumCalls.isEmpty)
    }

    func testMintsAndMarksAnAlbumWithoutMarker() async throws {
        let drive = try await makeDriveAlbum()

        let outcome = await run(drive)

        guard case .prepared(let albumID) = outcome else { return XCTFail("expected prepared, got \(outcome)") }
        XCTAssertNotNil(UUID(uuidString: albumID), "a random UUID, never derived from the name")
        XCTAssertEqual(store.savedAlbumCalls.map(\.albumID), [albumID])
        XCTAssertEqual(markerFile(in: drive), .present(.init(albumID: albumID)))
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.dirty, false)
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       drive.folder.standardizedFileURL)
        let saved = try XCTUnwrap(store.savedAlbumCalls.first)
        XCTAssertEqual(Album.decryptedAlbumName(saved.encName, key: key), drive.album.name)
        XCTAssertEqual(saved.keyFingerprint, key.keyFingerprint)
    }

    /// An account whose zone was never created: the album lookup answers
    /// `zoneNotFound` until the album save creates the zone.
    func testAlbumWithoutMarkerIsSavedWhenTheZoneDoesNotExistYet() async throws {
        let drive = try await makeDriveAlbum()
        let store = self.store!
        store.fetchAlbumError = CloudKitMediaStoreError.zoneNotFound
        let migration = makeMigration(writeMarkerFile: { marker, folder in
            store.fetchAlbumError = nil
            try marker.write(toAlbumDirectory: folder)
        })

        let outcome = await run(drive, migration)

        guard case .prepared(let albumID) = outcome else { return XCTFail("expected prepared, got \(outcome)") }
        XCTAssertEqual(store.savedAlbumCalls.map(\.albumID), [albumID], "a missing zone reads as no album, so it is saved")
        XCTAssertEqual(markerFile(in: drive), .present(.init(albumID: albumID)))
    }

    func testKilledBetweenSaveAndMarkerWriteResumesSameAlbumID() async throws {
        let drive = try await makeDriveAlbum()
        struct Killed: Error {}

        let first = await run(drive, makeMigration(writeMarkerFile: { _, _ in throw Killed() }))

        guard case .skipped(.failed(step: "writeMarkerFile", _)) = first else {
            return XCTFail("expected the marker write to fail, got \(first)")
        }
        let savedID = try XCTUnwrap(store.savedAlbumCalls.first?.albumID)
        touchedAlbumIDs.insert(savedID)
        XCTAssertEqual(markerFile(in: drive), .absent)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: savedID))
        let planBeforeResume = await plan(drive, albumID: savedID)
        XCTAssertNil(planBeforeResume)

        let second = await run(drive)

        XCTAssertEqual(second, .prepared(albumID: savedID), "the saved album is found by name, not minted again")
        XCTAssertEqual(store.savedAlbumCalls.count, 1, "the record already on the server is not saved again")
        XCTAssertEqual(markerFile(in: drive), .present(.init(albumID: savedID)))
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: savedID))
    }

    /// The sync's pass and a user's start run on separate instances. The album
    /// query lags behind the save, so a second run that resolved the id alongside
    /// the first would mint a second album; it waits instead and joins the first.
    func testConcurrentRunsForOneFolderLandOnOneAlbum() async throws {
        let drive = try await makeDriveAlbum()
        let store = self.store!
        store.fetchAllAlbumsGate = { try? await Task.sleep(nanoseconds: 50_000_000) }
        let writeMarker: (ICloudDriveAlbumMarkerFile, URL) throws -> Void = { marker, folder in
            store.albumsMissingFromQuery.insert(marker.albumID)
            try marker.write(toAlbumDirectory: folder)
        }
        let syncPass = makeMigration(writeMarkerFile: writeMarker)
        let userStart = makeMigration(writeMarkerFile: writeMarker)
        let album = drive.album

        async let fromSync = syncPass.run(folder: drive.folder)
        async let fromUser = userStart.run(album: album)
        let outcomes = await [fromSync, fromUser]

        guard case .prepared(let albumID) = outcomes[0] else { return XCTFail("expected prepared, got \(outcomes[0])") }
        touchedAlbumIDs.insert(albumID)
        XCTAssertEqual(outcomes[1], .prepared(albumID: albumID), "both runs land on the same album")
        XCTAssertEqual(store.savedAlbumCalls.map(\.albumID), [albumID], "only one album is saved")
        XCTAssertEqual(markerFile(in: drive), .present(.init(albumID: albumID)))
    }

    func testWritesMarkerOnlyAfterRecordSave() async throws {
        let drive = try await makeDriveAlbum()
        let store = self.store!
        var serverHadRecordAtMarkerWrite: Bool?
        let migration = makeMigration(writeMarkerFile: { marker, folder in
            serverHadRecordAtMarkerWrite = store.savedAlbumCalls.contains { $0.albumID == marker.albumID }
            try marker.write(toAlbumDirectory: folder)
        })

        let outcome = await run(drive, migration)

        guard case .prepared = outcome else { return XCTFail("expected prepared, got \(outcome)") }
        XCTAssertEqual(serverHadRecordAtMarkerWrite, true)

        // A save that fails leaves no marker behind.
        let other = try await makeDriveAlbum()
        store.saveAlbumError = CloudKitMediaStoreError.accountUnavailable
        var markerWrites = 0
        let failing = await run(other, makeMigration(writeMarkerFile: { _, _ in markerWrites += 1 }))

        guard case .skipped(.failed(step: "saveAlbum", _)) = failing else {
            return XCTFail("expected the save to fail, got \(failing)")
        }
        XCTAssertEqual(markerWrites, 0)
        XCTAssertEqual(markerFile(in: other), .absent)
    }

    func testDoesNotSetMigrationInProgress() async throws {
        let drive = try await makeDriveAlbum()

        let outcome = await run(drive)

        guard case .prepared(let albumID) = outcome else { return XCTFail("expected prepared, got \(outcome)") }
        let saved = try XCTUnwrap(store.savedAlbumCalls.first)
        XCTAssertNil(saved.migrationInProgress, "the flag is not written")
        let onServer = try await store.fetchAlbum(albumID: albumID)
        XCTAssertEqual(onServer?.migrationInProgress, false)
        let hidden = await CloudKitAlbumMembership.isBeingFilled(try XCTUnwrap(onServer), store: store)
        XCTAssertFalse(hidden, "other devices list the album at once")
    }

    func testWritesNoMediaRecords() async throws {
        let drive = try await makeDriveAlbum(count: 3)
        let before = try mediaSnapshot(drive)

        let outcome = await run(drive)

        guard case .prepared(let albumID) = outcome else { return XCTFail("expected prepared, got \(outcome)") }
        XCTAssertTrue(store.uploadCalls.isEmpty)
        XCTAssertTrue(store.uploadedItems.isEmpty)
        XCTAssertTrue(store.liveRecordNames.isEmpty)
        XCTAssertFalse(store.callOrder.contains {
            switch $0 {
            case .upload, .reassignAlbum, .delete, .attachThumbnail: return true
            default: return false
            }
        })
        XCTAssertEqual(try mediaSnapshot(drive), before, "the folder's media is untouched")

        // The plan holds every component as pending work, classified by kind.
        let loaded = await plan(drive, albumID: albumID)
        let plan = try XCTUnwrap(loaded)
        XCTAssertEqual(plan.scope, .album)
        XCTAssertEqual(plan.source.storage, .icloud)
        XCTAssertEqual(plan.destination.storage, .cloudKit)
        XCTAssertEqual(Set(plan.items.map(\.mediaID)), Set(drive.mediaIDs))
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .pending })
        XCTAssertTrue(plan.items.allSatisfy { $0.sizeBytes > 0 })
        XCTAssertTrue(plan.items.allSatisfy { $0.kind == MigrationItemKind(mediaType: $0.mediaType, sizeBytes: $0.sizeBytes) })
        XCTAssertTrue(plan.items.allSatisfy { $0.kind == .ciphertextOnly })

        // Kept apart from the whole-album move: nothing resumes it as one.
        XCTAssertFalse(MigrationPlanStore.hasPlans(for: drive.album))
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: drive.album.id), MigrationPlanRole.none)
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: "\(albumID)_cloudKit"), MigrationPlanRole.none)
        let pending = await CloudKitMigrationManager(albumManager: albumManager, storeFactory: { [store] _ in store! })
            .pendingPlans()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Parity

    /// Every run indexes the folder into the CloudKit album and removes the files
    /// whose upload landed, through the verified delete; a run in parity changes
    /// nothing.
    func testEveryRunIndexesFolderAndSweepsFilesAlreadyInCloudKit() async throws {
        let drive = try await makeDriveAlbum(count: 2)

        let first = await run(drive)

        guard case .prepared(let albumID) = first else { return XCTFail("expected prepared, got \(first)") }
        let indexStore = try XCTUnwrap(albumManager.mediaIndexStore(forAlbumID: albumID))
        let indexed = await indexStore.reloadFromDisk()?.entries ?? []
        XCTAssertEqual(Set(indexed.map(\.id)), Set(drive.mediaIDs))
        XCTAssertTrue(indexed.allSatisfy { $0.hasPhotoComponent && $0.photoLocation == .iCloudDrive })
        XCTAssertEqual(try mediaSnapshot(drive).count, 2)

        // One item's upload landed and the sync placed it in CloudKit; its file
        // was never deleted.
        let uploaded = drive.mediaIDs[0]
        let uploadedURL = drive.folder.appendingPathComponent("\(uploaded).\(MediaType.photo.encryptedFileExtension)")
        let size = try XCTUnwrap(uploadedURL.fileSizeBytes())
        store.metadataToReturn.append(CloudKitMediaMetadata(
            recordName: MediaRecordName.componentRecordName(mediaID: uploaded, type: .photo), albumID: albumID,
            mediaID: uploaded, mediaType: .photo, createdAt: Date(), sizeBytes: size,
            creationDeviceID: "other-device", schemaVersion: 1, recordChangeTag: "tag"))
        try await indexStore.upsert([MediaIndexEntry(id: uploaded, hasPhotoComponent: true, hasVideoComponent: false,
                                                     dateEncrypted: Date(), dateTaken: Date(), subtypeRawValue: 0)])

        let second = await run(drive)

        XCTAssertEqual(second, .prepared(albumID: albumID))
        XCTAssertFalse(ICloudPlaceholderName.existsInAnyForm(uploadedURL))
        let remaining = try mediaSnapshot(drive)
        XCTAssertEqual(Array(remaining.keys), ["\(drive.mediaIDs[1]).\(MediaType.photo.encryptedFileExtension)"])
        let indexAfterSecond = await indexStore.reloadFromDisk()?.entries

        let third = await run(drive)

        XCTAssertEqual(third, .prepared(albumID: albumID))
        XCTAssertEqual(try mediaSnapshot(drive), remaining)
        let indexAfterThird = await indexStore.reloadFromDisk()?.entries
        XCTAssertEqual(indexAfterThird, indexAfterSecond)
    }

    func testOfflineOrNoAccountLeavesAlbumAsICloudDrive() async throws {
        let drive = try await makeDriveAlbum()
        let before = try mediaSnapshot(drive)

        let offline = await run(drive, makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { false }, isOnUnmeteredNetwork: { false })))
        XCTAssertEqual(offline, .skipped(.offline))

        let locked = await run(drive, makeMigration(conditions: .init(isUnlocked: { false }, hasNetwork: { true }, isOnUnmeteredNetwork: { true })))
        XCTAssertEqual(locked, .skipped(.locked))

        store.accountAvailableValue = false
        let signedOut = await run(drive)
        XCTAssertEqual(signedOut, .skipped(.accountUnavailable))

        XCTAssertTrue(serverAlbumCalls.isEmpty)
        XCTAssertEqual(markerFile(in: drive), .absent)
        XCTAssertEqual(try mediaSnapshot(drive), before)
        assertNothingWritten(drive)
        assertListedAsICloudDriveOnly(drive)
    }

    // MARK: - Wi-Fi only

    private func offWiFi() -> ICloudDriveAlbumMigration.MigrationDeviceConditions {
        .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { false })
    }

    func testAlbumStepOffWiFiSkipsWithWaitingForWiFi() async throws {
        let drive = try await makeDriveAlbum()

        let outcome = await run(drive, makeMigration(conditions: offWiFi()))
        XCTAssertEqual(outcome, .skipped(.waitingForWiFi))

        let pass = await makeMigration(conditions: offWiFi(), albumFolders: { [drive.folder] }).runEveryFolder()
        XCTAssertEqual(pass, .skipped(.waitingForWiFi))
        XCTAssertEqual(storesMade, 0, "nothing reaches CloudKit off Wi-Fi, not even the account check")

        // On Wi-Fi the same album runs as before.
        let onWiFi = await run(drive, makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { true },
                                                                      isOnUnmeteredNetwork: { true })))
        guard case .prepared = onWiFi else { return XCTFail("expected prepared on Wi-Fi, got \(onWiFi)") }
    }

    func testAlbumStepOffWiFiWritesNoMarkerOrRecord() async throws {
        let drive = try await makeDriveAlbum()
        let before = try mediaSnapshot(drive)

        _ = await run(drive, makeMigration(conditions: offWiFi()))

        XCTAssertTrue(serverAlbumCalls.isEmpty)
        XCTAssertEqual(markerFile(in: drive), .absent, "no marker file off Wi-Fi")
        XCTAssertEqual(try mediaSnapshot(drive), before)
        XCTAssertTrue(blobMigrationStarts.isEmpty)
        assertNothingWritten(drive)
        assertListedAsICloudDriveOnly(drive)
    }

    func testWiFiReturnStartsSkippedAlbumStep() async throws {
        let drive = try await makeDriveAlbum()
        let onWiFi = WiFiFlag()
        let center = NotificationCenter()
        let migration = makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { true },
                                                        isOnUnmeteredNetwork: { onWiFi.value }),
                                      albumFolders: { [drive.folder] })
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false,
                                      makeICloudDriveAlbumMigration: { _ in migration },
                                      networkNotificationCenter: center)

        let ranOffWiFi = await sync.migrateICloudDriveAlbums()
        XCTAssertFalse(ranOffWiFi)
        let waiting = await sync.albumMigrationWaitingForWiFi
        XCTAssertTrue(waiting)
        XCTAssertEqual(markerFile(in: drive), .absent)

        // A path change that is still not Wi-Fi runs nothing.
        center.post(name: NetworkMonitor.pathDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(markerFile(in: drive), .absent)

        onWiFi.value = true
        center.post(name: NetworkMonitor.pathDidChange, object: nil)

        let deadline = Date().addingTimeInterval(10)
        while blobMigrationStarts.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let start = try XCTUnwrap(blobMigrationStarts.first, "Wi-Fi returning runs the skipped album step without a relaunch")
        touchedAlbumIDs.insert(start.albumID)
        guard case .present(let marker) = markerFile(in: drive) else { return XCTFail("expected a marker file") }
        XCTAssertEqual(marker.albumID, start.albumID)
        let stillWaiting = await sync.albumMigrationWaitingForWiFi
        XCTAssertFalse(stillWaiting)
    }

    func testWiFiReturnRerunsAlbumStepAUserMoveSkipped() async throws {
        let drive = try await makeDriveAlbum()
        let onWiFi = WiFiFlag()
        onWiFi.value = true
        let center = NotificationCenter()
        let migration = makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { true },
                                                        isOnUnmeteredNetwork: { onWiFi.value }),
                                      albumFolders: { [] })
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false,
                                      makeICloudDriveAlbumMigration: { _ in migration },
                                      networkNotificationCenter: center)
        let ranOnWiFi = await sync.migrateICloudDriveAlbums()
        XCTAssertTrue(ranOnWiFi)
        let waitingAfterLaunch = await sync.albumMigrationWaitingForWiFi
        XCTAssertFalse(waitingAfterLaunch)

        // The user starts the move on cellular, outside the sync's own run.
        onWiFi.value = false
        let userMove = await run(drive, migration)
        XCTAssertEqual(userMove, .skipped(.waitingForWiFi))
        let waiting = await sync.albumMigrationWaitingForWiFi
        XCTAssertTrue(waiting, "a user move skipped for Wi-Fi is run again when Wi-Fi returns")
    }

    func testOfflineSkipWaitsForWiFi() async throws {
        let drive = try await makeDriveAlbum()
        let migration = makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { false },
                                                        isOnUnmeteredNetwork: { false }),
                                      albumFolders: { [drive.folder] })
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false,
                                      makeICloudDriveAlbumMigration: { _ in migration },
                                      networkNotificationCenter: NotificationCenter())

        _ = await sync.migrateICloudDriveAlbums()

        let waiting = await sync.albumMigrationWaitingForWiFi
        XCTAssertTrue(waiting, "a launch with no network runs the album step again when the network changes")
    }

    // MARK: - Markers that cannot be used as they are

    func testEvictedMarkerRequestsDownloadAndMintsNothing() async throws {
        let drive = try await makeDriveAlbum()
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: drive.folder)
        try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL))

        let outcome = await run(drive)

        XCTAssertEqual(outcome, .skipped(.markerEvicted))
        XCTAssertEqual(downloads.map(\.standardizedFileURL), [markerURL.standardizedFileURL])
        XCTAssertTrue(serverAlbumCalls.isEmpty, "no id is resolved over a marker that exists")
        assertNothingWritten(drive)
    }

    func testConflictedMarkerIsLeftToTheWalk() async throws {
        let drive = try await makeDriveAlbum()
        try ICloudDriveAlbumMarkerFile(albumID: UUID().uuidString).write(toAlbumDirectory: drive.folder)
        let version = scratch.appendingPathComponent("version.json")
        try ICloudDriveAlbumMarkerFile(albumID: UUID().uuidString).encoded().write(to: version)

        let outcome = await run(drive, makeMigration(conflictVersions: { _ in [version] }))

        XCTAssertEqual(outcome, .skipped(.markerConflicted))
        XCTAssertTrue(serverAlbumCalls.isEmpty)
        assertNothingWritten(drive)
    }

    func testUnreadableMarkerMintsNothing() async throws {
        let drive = try await makeDriveAlbum()
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: drive.folder)
        try Data("{\"formatVersion\": 99, \"albumID\": \"x\"}".utf8).write(to: markerURL)

        let outcome = await run(drive)

        XCTAssertEqual(outcome, .skipped(.markerUnreadable))
        XCTAssertTrue(serverAlbumCalls.isEmpty)
        assertNothingWritten(drive)
        XCTAssertEqual(try Data(contentsOf: markerURL), Data("{\"formatVersion\": 99, \"albumID\": \"x\"}".utf8),
                       "the marker is left as it is")
    }

    func testMarkerNamingDeletedAlbumIsNotSavedAgain() async throws {
        let drive = try await makeDriveAlbum()
        let gone = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: gone).write(toAlbumDirectory: drive.folder)
        publishRegistry.markConfirmedOnServer(gone)

        let outcome = await run(drive)

        XCTAssertEqual(outcome, .skipped(.recordGone(albumID: gone)))
        XCTAssertEqual(serverAlbumCalls, [.fetchAlbum(albumID: gone)])
        assertNothingWritten(drive)
        XCTAssertEqual(markerFile(in: drive), .present(.init(albumID: gone)))
        assertListedAsICloudDriveOnly(drive)

        // Never seen published: it may still be on its way, so it is waited for.
        let pending = UUID().uuidString
        let other = try await makeDriveAlbum()
        try ICloudDriveAlbumMarkerFile(albumID: pending).write(toAlbumDirectory: other.folder)
        let waiting = await run(other)
        XCTAssertEqual(waiting, .skipped(.recordNotVisibleYet(albumID: pending)))
        assertNothingWritten(other)
    }

    // MARK: - Conflicting markers from two devices

    /// The fake `NSFileVersion` store for one marker file.
    private final class Versions: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL]
        init(_ urls: [URL]) { _urls = urls }
        var urls: [URL] {
            get { lock.withLock { _urls } }
            set { lock.withLock { _urls = newValue } }
        }
    }

    func testMarkerChangedBeforeLinkingStopsAndNextRunFollowsIt() async throws {
        let drive = try await makeDriveAlbum()
        let winner = UUID().uuidString
        store.seedAlbum(record(albumID: winner, for: drive.album, createdAt: Date(timeIntervalSince1970: 1)))
        store.albumsMissingFromQuery = [winner]
        // The marker this run writes is replaced by the version the walk keeps.
        let migration = makeMigration(writeMarkerFile: { _, folder in
            try ICloudDriveAlbumMarkerFile(albumID: winner).write(toAlbumDirectory: folder)
        })

        let first = await run(drive, migration)

        guard case .skipped(.markerChanged(let ownID)) = first else {
            return XCTFail("expected the run to stop, got \(first)")
        }
        touchedAlbumIDs.insert(ownID)
        XCTAssertNotEqual(ownID, winner)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: ownID))
        let ownPlan = await plan(drive, albumID: ownID)
        XCTAssertNil(ownPlan)

        let second = await run(drive)

        XCTAssertEqual(second, .prepared(albumID: winner))
        let winnerPlan = await plan(drive, albumID: winner)
        XCTAssertNotNil(winnerPlan)
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: winner)?.standardizedFileURL,
                       drive.folder.standardizedFileURL)
    }

    func testWalkDeletingEmptyLosingAlbumRemovesItsPlan() async throws {
        let drive = try await makeDriveAlbum()
        let prepared = await run(drive)
        guard case .prepared(let loser) = prepared else { return XCTFail("expected prepared, got \(prepared)") }
        XCTAssertTrue(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: loser))

        // Another device migrated the folder at the same time into an album that
        // sorts first.
        let winner = UUID().uuidString
        store.seedAlbum(record(albumID: winner, for: drive.album, createdAt: Date(timeIntervalSince1970: 1)))
        let version = scratch.appendingPathComponent("version.json")
        try ICloudDriveAlbumMarkerFile(albumID: winner).encoded().write(to: version)
        let versions = Versions([version])
        let walk = ICloudDriveAlbumFolderWalk(albumManager: albumManager,
                                              makeStore: { [store] in store! },
                                              publishRegistry: publishRegistry,
                                              deleteQueue: deleteQueue,
                                              requestMarkerDownload: { _ in },
                                              conflictVersions: { _ in versions.urls },
                                              resolveMarkerConflict: { url, kept in
                                                  try kept.write(toAlbumDirectory: url.deletingLastPathComponent())
                                                  versions.urls = []
                                              },
                                              uploadQueue: CloudKitUploadQueue(baseDir: scratch.appendingPathComponent("queue")))

        _ = await walk.run()

        XCTAssertEqual(store.deletedAlbumCalls, [loser])
        XCTAssertFalse(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: loser),
                       "no plan is left naming the deleted album")
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: loser))

        let next = await run(drive)
        XCTAssertEqual(next, .prepared(albumID: winner))
        XCTAssertTrue(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: winner))
    }

    // MARK: - Flip

    /// The albums named like `drive`'s, in either storage, in an album list.
    private func listed(_ drive: DriveAlbum, in albums: [Album]) -> [StorageType] {
        albums.filter { $0.name == drive.album.name }.map(\.storageOption).sorted { $0.rawValue < $1.rawValue }
    }

    /// Runs the migration on `drive`, sampling the album list after the marker
    /// write, when the parity sweep starts, and in every album list the manager
    /// publishes. Returns the outcome, the samples, the published lists, and
    /// whether the album's index file existed each time the CloudKit album was
    /// published.
    private func runObservingAlbumList(_ drive: DriveAlbum) async -> (outcome: ICloudDriveAlbumMigration.AlbumMigrationRunOutcome,
                                                                       samples: [[StorageType]],
                                                                       published: [[StorageType]],
                                                                       indexBuiltAtPublish: [Bool],
                                                                       heldDuringRun: [Bool]) {
        var samples: [[StorageType]] = []
        var published: [[StorageType]] = []
        var indexBuiltAtPublish: [Bool] = []
        var heldDuringRun: [Bool] = []
        let registry = ICloudDriveAlbumFlipRegistry()
        let sample = { [unowned self] in
            samples.append(listed(drive, in: albumManager.fetchAlbumsFromSources(includingHidden: true)))
        }
        let indexBuilt = { (album: Album) -> Bool in
            FileManager.default.fileExists(atPath: MediaIndexStore.indexURL(for: album).path)
        }
        let subscription = albumManager.albumOperationPublisher.sink { [unowned self] operation in
            switch operation {
            case .albumsUpdated(let albums):
                published.append(listed(drive, in: albums))
                if let cloudKit = albums.first(where: { $0.storageOption == .cloudKit && $0.name == drive.album.name }) {
                    indexBuiltAtPublish.append(indexBuilt(cloudKit))
                }
            case .albumCreated(let album) where album.storageOption == .cloudKit:
                indexBuiltAtPublish.append(indexBuilt(album))
            default:
                break
            }
        }
        defer { subscription.cancel() }
        let migration = makeMigration(writeMarkerFile: { marker, folder in
                                          try marker.write(toAlbumDirectory: folder)
                                          sample()
                                      },
                                      makeVerifiedDelete: { store in
                                          sample()
                                          if case .present(let marker) = ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: drive.folder,
                                                                                                         conflictVersions: { _ in [] }) {
                                              heldDuringRun.append(registry.isHeld(marker.albumID))
                                          }
                                          return ICloudDriveVerifiedDelete(store: store)
                                      },
                                      flipRegistry: registry)
        let outcome = await run(drive, migration)
        sample()
        if case .prepared(let albumID) = outcome { heldDuringRun.append(registry.isHeld(albumID)) }
        return (outcome, samples, published, indexBuiltAtPublish, heldDuringRun)
    }

    /// The album list shows exactly one of the two albums at every point of a run:
    /// the iCloud Drive album until the index is built, then the CloudKit album.
    /// Both for an album this run mints and one another device's marker names.
    func testFlipShowsExactlyOneAlbumThroughout() async throws {
        let minted = try await makeDriveAlbum(count: 2)

        let first = await runObservingAlbumList(minted)

        guard case .prepared = first.outcome else { return XCTFail("expected prepared, got \(first.outcome)") }
        XCTAssertEqual(first.samples, [[.icloud], [.icloud], [.cloudKit]],
                       "the folder is listed until the flip, the CloudKit album after it, never both or neither")
        XCTAssertFalse(first.published.isEmpty, "the flip is published")
        XCTAssertTrue(first.published.allSatisfy { $0 == [.cloudKit] }, "published lists: \(first.published)")
        XCTAssertFalse(first.indexBuiltAtPublish.isEmpty)
        XCTAssertTrue(first.indexBuiltAtPublish.allSatisfy { $0 }, "the CloudKit album is listed only once indexed")
        XCTAssertEqual(first.heldDuringRun, [true, false], "the run holds the flip until it ends")

        let marked = try await makeDriveAlbum(count: 1)
        let albumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: marked.folder)
        store.seedAlbum(record(albumID: albumID, for: marked.album))

        let second = await runObservingAlbumList(marked)

        XCTAssertEqual(second.outcome, .prepared(albumID: albumID))
        XCTAssertEqual(second.samples, [[.icloud], [.cloudKit]])
        XCTAssertTrue(second.published.allSatisfy { $0 == [.cloudKit] }, "published lists: \(second.published)")
        XCTAssertTrue(second.indexBuiltAtPublish.allSatisfy { $0 })
        XCTAssertFalse(second.indexBuiltAtPublish.isEmpty)
        XCTAssertEqual(second.heldDuringRun, [true, false])
        let indexStore = try XCTUnwrap(albumManager.mediaIndexStore(forAlbumID: albumID))
        let indexed = await indexStore.reloadFromDisk()?.entries ?? []
        XCTAssertEqual(Set(indexed.map(\.id)), Set(marked.mediaIDs))
    }

    /// While a run holds an album's flip, neither the album-folder walk nor the
    /// reconciler adopts it; once the run lets go, the walk adopts it as before.
    func testWalkAndReconcilerLeaveAnAlbumARunFlipsUnadopted() async throws {
        let drive = try await makeDriveAlbum()
        let albumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: drive.folder)
        store.seedAlbum(record(albumID: albumID, for: drive.album))
        let registry = ICloudDriveAlbumFlipRegistry()
        registry.begin(albumID)
        let uploadQueue = CloudKitUploadQueue(baseDir: scratch.appendingPathComponent("queue"))
        let walk = ICloudDriveAlbumFolderWalk(albumManager: albumManager,
                                              makeStore: { [store] in store! },
                                              publishRegistry: publishRegistry,
                                              deleteQueue: deleteQueue,
                                              requestMarkerDownload: { _ in },
                                              conflictVersions: { _ in [] },
                                              uploadQueue: uploadQueue,
                                              flipRegistry: registry)
        let reconciler = CloudKitAlbumReconciler(store: store, keyManager: albumManager.keyManager,
                                                 albumManager: albumManager, deleteQueue: deleteQueue,
                                                 publishRegistry: publishRegistry, uploadQueue: uploadQueue,
                                                 flipRegistry: registry)

        _ = await walk.run()
        _ = await reconciler.reconcileAlbums(changes: .none)

        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(listed(drive, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.icloud])

        registry.end(albumID)
        _ = await walk.run()

        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(listed(drive, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.cloudKit])
    }

    /// A folder the CloudKit album links, still holding its media, is never
    /// listed, even while its marker is evicted, and is never re-created, even
    /// after the CloudKit album is renamed so no name matches it.
    func testLinkedFolderWithMediaIsNotRecreatedOrShown() async throws {
        let drive = try await makeDriveAlbum(count: 2)
        let outcome = await run(drive)
        guard case .prepared(let albumID) = outcome else { return XCTFail("expected prepared, got \(outcome)") }
        XCTAssertEqual(try mediaSnapshot(drive).count, 2)

        let model = iCloudStorageModel(album: drive.album)
        XCTAssertTrue(model.isLinkedICloudDriveFolder)
        XCTAssertTrue(model.hasMigratedToCloudKit, "the folder is left alone")
        XCTAssertFalse(model.isDrainedICloudDriveSource, "a full linked folder is not drained")
        XCTAssertEqual(listed(drive, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.cloudKit])

        // The marker is evicted: the link alone keeps the folder out of the list.
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: drive.folder)
        try FileManager.default.moveItem(at: markerURL, to: ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL))
        XCTAssertEqual(markerFile(in: drive), .evicted)
        XCTAssertEqual(listed(drive, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.cloudKit])
        try FileManager.default.moveItem(at: ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL), to: markerURL)

        // Renamed elsewhere: no CloudKit album matches the folder's name any more.
        var marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        marker.encName = Album.cloudKitTwin(of: Album(name: "renamed-\(UUID().uuidString)", storageOption: .icloud,
                                                      creationDate: Date(), key: key),
                                            albumID: albumID).encryptedPathComponent
        try marker.write(albumID: albumID)
        XCTAssertNil(CloudKitAlbumMarker.albumID(matching: drive.album))
        XCTAssertTrue(model.hasMigratedToCloudKit)
        XCTAssertFalse(model.isDrainedICloudDriveSource)

        // The folder goes missing on this device: nothing re-creates it.
        let away = scratch.appendingPathComponent("away", isDirectory: true)
        try FileManager.default.moveItem(at: drive.folder, to: away)
        try model.initializeDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.folder.path), "the linked folder is not re-created")
        let backend = DiskMediaBackend()
        await backend.configure(for: drive.album, albumManager: albumManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.folder.path))
        XCTAssertFalse(albumManager.fetchAlbumsFromSources(includingHidden: true)
            .contains { $0.storageOption == .icloud && $0.name == drive.album.name })
    }

    // MARK: - Every launch

    private final class DeleteSpy: ICloudDriveComponentDeleting, @unchecked Sendable {
        private let lock = NSLock()
        private var _recordNames: [String] = []
        var recordNames: [String] { lock.withLock { _recordNames } }

        func delete(recordName: String, albumID: String, folder: URL) async -> ICloudDriveVerifiedDeleteResult {
            lock.withLock { _recordNames.append(recordName) }
            return .skipped(.recordMissing)
        }
    }

    private func byFolderName(_ outcomes: [URL: ICloudDriveAlbumMigration.AlbumMigrationRunOutcome]) -> [String: ICloudDriveAlbumMigration.AlbumMigrationRunOutcome] {
        Dictionary(uniqueKeysWithValues: outcomes.map { ($0.key.lastPathComponent, $0.value) })
    }

    /// The index file of the CloudKit album `albumID`, if this device has one.
    private func indexEntries(albumID: String) async -> [MediaIndexEntry]? {
        await albumManager.mediaIndexStore(forAlbumID: albumID)?.reloadFromDisk()?.entries
    }

    /// A pass runs for every album folder, one whose marker already names an
    /// album included, hands each prepared album to the blob migration, and asks
    /// for a whole-zone walk for each index it creates. A second pass over albums
    /// and folders in parity saves nothing, deletes nothing and changes no index.
    func testRunsForEveryFolderIncludingAlreadyMarked() async throws {
        let marked = try await makeDriveAlbum(count: 1)
        let fresh = try await makeDriveAlbum(count: 2)
        let earlier = await run(marked)
        guard case .prepared(let markedID) = earlier else { return XCTFail("expected prepared, got \(earlier)") }
        blobMigrationStarts = []
        let spy = DeleteSpy()
        let migration = makeMigration(makeVerifiedDelete: { _ in spy })

        let first = await migration.runEveryFolder()

        guard case .ran(let ran) = first else { return XCTFail("expected a pass, got \(first)") }
        let outcomes = byFolderName(ran)
        XCTAssertEqual(outcomes.count, 2, "both folders, the one already marked included")
        XCTAssertEqual(outcomes[marked.folder.lastPathComponent], .prepared(albumID: markedID))
        guard case .prepared(let freshID) = outcomes[fresh.folder.lastPathComponent] else {
            return XCTFail("expected the unmarked folder prepared, got \(outcomes)")
        }
        touchedAlbumIDs.insert(freshID)
        XCTAssertEqual(markerFile(in: fresh), .present(ICloudDriveAlbumMarkerFile(albumID: freshID)))
        XCTAssertEqual(Set(blobMigrationStarts.map { "\($0.albumID)/\($0.folder.lastPathComponent)" }),
                       ["\(markedID)/\(marked.folder.lastPathComponent)", "\(freshID)/\(fresh.folder.lastPathComponent)"])
        XCTAssertTrue(zoneWalkRequests.requested().isSuperset(of: [markedID, freshID]),
                      "each album whose index the run created gets a whole-zone walk")
        let freshIndex = await indexEntries(albumID: freshID)
        XCTAssertEqual(Set(freshIndex?.map(\.id) ?? []), Set(fresh.mediaIDs))

        let savesBefore = store.savedAlbumCalls.count
        let filesBefore = [try mediaSnapshot(marked), try mediaSnapshot(fresh)]
        let indexesBefore = [await indexEntries(albumID: markedID), await indexEntries(albumID: freshID)]
        let markedPlanBefore = await plan(marked, albumID: markedID)?.items
        let freshPlanBefore = await plan(fresh, albumID: freshID)?.items

        let second = await migration.runEveryFolder()

        guard case .ran(let ranAgain) = second else { return XCTFail("expected a pass, got \(second)") }
        XCTAssertEqual(byFolderName(ranAgain), [marked.folder.lastPathComponent: .prepared(albumID: markedID),
                                                fresh.folder.lastPathComponent: .prepared(albumID: freshID)])
        XCTAssertEqual(store.savedAlbumCalls.count, savesBefore, "no album record saved again")
        XCTAssertTrue(store.uploadCalls.isEmpty)
        XCTAssertTrue(spy.recordNames.isEmpty, "nothing in parity is passed to the delete")
        XCTAssertEqual([try mediaSnapshot(marked), try mediaSnapshot(fresh)], filesBefore)
        let indexesAfter = [await indexEntries(albumID: markedID), await indexEntries(albumID: freshID)]
        XCTAssertEqual(indexesAfter, indexesBefore)
        let markedPlanAfter = await plan(marked, albumID: markedID)?.items
        let freshPlanAfter = await plan(fresh, albumID: freshID)?.items
        XCTAssertEqual(markedPlanAfter, markedPlanBefore)
        XCTAssertEqual(freshPlanAfter, freshPlanBefore)
        XCTAssertEqual(listed(marked, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.cloudKit])
        XCTAssertEqual(listed(fresh, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.cloudKit])
    }

    /// While the phone is locked (protected data unavailable) or the app runs in
    /// the background, as in a background task run, a pass lists no
    /// folder and a run reaches nothing. The device conditions read the phone's
    /// own protected-data and run state.
    func testSkipsWhenLockedOrProtectedDataUnavailable() async throws {
        let drive = try await makeDriveAlbum()
        let before = try mediaSnapshot(drive)
        var listedFolders = 0
        let countFolders = { () -> [URL] in
            listedFolders += 1
            return [drive.folder]
        }

        let locked = makeMigration(conditions: .init(isUnlocked: { false }, hasNetwork: { true }, isOnUnmeteredNetwork: { true }),
                                   albumFolders: countFolders)
        let lockedPass = await locked.runEveryFolder()
        XCTAssertEqual(lockedPass, .skipped(.locked))
        let lockedRun = await locked.run(album: drive.album)
        XCTAssertEqual(lockedRun, .skipped(.locked))

        let background = makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                         isInBackground: { true }),
                                       albumFolders: countFolders)
        let backgroundPass = await background.runEveryFolder()
        XCTAssertEqual(backgroundPass, .skipped(.inBackground))
        let backgroundRun = await run(drive, background)
        XCTAssertEqual(backgroundRun, .skipped(.inBackground))

        XCTAssertEqual(listedFolders, 0, "no folder is listed")
        XCTAssertEqual(storesMade, 0, "nothing reaches the server")
        XCTAssertEqual(markerFile(in: drive), .absent)
        XCTAssertEqual(try mediaSnapshot(drive), before)
        XCTAssertTrue(blobMigrationStarts.isEmpty)
        assertNothingWritten(drive)
        assertListedAsICloudDriveOnly(drive)

        let device = ICloudDriveAlbumMigration.MigrationDeviceConditions.device
        XCTAssertEqual(device.isUnlocked(), ProtectedDataAvailability.isAvailable)
        XCTAssertEqual(device.isInBackground(), AppRunState.isInBackground)
        #if canImport(UIKit)
        XCTAssertEqual(device.isUnlocked(), UIApplication.shared.isProtectedDataAvailable)
        XCTAssertEqual(device.isInBackground(), UIApplication.shared.applicationState == .background)
        #endif
    }

    /// Offline, or with the account unavailable, a pass lists no folder and leaves
    /// every iCloud Drive album exactly as it was.
    func testSkipsWhenOfflineOrNoAccount() async throws {
        let first = try await makeDriveAlbum()
        let second = try await makeDriveAlbum(count: 1)
        let before = [try mediaSnapshot(first), try mediaSnapshot(second)]
        var listedFolders = 0
        let countFolders = { () -> [URL] in
            listedFolders += 1
            return [first.folder, second.folder]
        }

        let offline = makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { false }, isOnUnmeteredNetwork: { false }),
                                    albumFolders: countFolders)
        let offlinePass = await offline.runEveryFolder()
        XCTAssertEqual(offlinePass, .skipped(.offline))

        store.accountAvailableValue = false
        let signedOut = makeMigration(albumFolders: countFolders)
        let signedOutPass = await signedOut.runEveryFolder()
        XCTAssertEqual(signedOutPass, .skipped(.accountUnavailable))

        XCTAssertEqual(listedFolders, 0, "no folder is listed")
        XCTAssertTrue(serverAlbumCalls.isEmpty)
        XCTAssertTrue(blobMigrationStarts.isEmpty)
        XCTAssertEqual(markerFile(in: first), .absent)
        XCTAssertEqual(markerFile(in: second), .absent)
        XCTAssertEqual([try mediaSnapshot(first), try mediaSnapshot(second)], before)
        assertNothingWritten(first)
        assertListedAsICloudDriveOnly(first)
        assertListedAsICloudDriveOnly(second)
    }

    /// With iCloud Drive off for the app, nothing runs: no folder is listed or
    /// read, no record is fetched, nothing is indexed, swept or deleted, and the
    /// blob migration never starts. That holds for a folder whose marker names an
    /// album with a file already in CloudKit, which a run would sweep.
    func testDeviceWithoutICloudDriveNeverScansSweepsOrDeletes() async throws {
        let drive = try await makeDriveAlbum(count: 2)
        let albumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: drive.folder)
        store.seedAlbum(record(albumID: albumID, for: drive.album))
        let uploaded = drive.mediaIDs[0]
        let uploadedURL = drive.folder.appendingPathComponent("\(uploaded).\(MediaType.photo.encryptedFileExtension)")
        store.metadataToReturn.append(CloudKitMediaMetadata(
            recordName: MediaRecordName.componentRecordName(mediaID: uploaded, type: .photo), albumID: albumID,
            mediaID: uploaded, mediaType: .photo, createdAt: Date(), sizeBytes: try XCTUnwrap(uploadedURL.fileSizeBytes()),
            creationDeviceID: "other-device", schemaVersion: 1, recordChangeTag: "tag"))
        let before = try mediaSnapshot(drive)
        var listedFolders = 0
        let spy = DeleteSpy()
        let migration = makeMigration(conditions: .init(isUnlocked: { true }, hasNetwork: { true }, isOnUnmeteredNetwork: { true },
                                                        hasICloudDrive: { false }),
                                      makeVerifiedDelete: { _ in spy },
                                      albumFolders: {
                                          listedFolders += 1
                                          return [drive.folder]
                                      })

        let pass = await migration.runEveryFolder()
        let folderRun = await migration.run(folder: drive.folder)
        let albumRun = await migration.run(album: drive.album)

        XCTAssertEqual(pass, .skipped(.iCloudDriveUnavailable))
        XCTAssertEqual(folderRun, .skipped(.iCloudDriveUnavailable))
        XCTAssertEqual(albumRun, .skipped(.iCloudDriveUnavailable))
        XCTAssertEqual(listedFolders, 0, "no folder is listed")
        XCTAssertEqual(storesMade, 0, "nothing reaches the server")
        XCTAssertTrue(store.callOrder.isEmpty)
        XCTAssertTrue(spy.recordNames.isEmpty, "nothing is deleted")
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(blobMigrationStarts.isEmpty)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID), "the album is not adopted from the folder")
        let index = await indexEntries(albumID: albumID)
        XCTAssertNil(index, "nothing is indexed")
        XCTAssertTrue(zoneWalkRequests.requested().isEmpty)
        XCTAssertEqual(try mediaSnapshot(drive), before)
        XCTAssertEqual(markerFile(in: drive), .present(ICloudDriveAlbumMarkerFile(albumID: albumID)))
        let plan = await plan(drive, albumID: albumID)
        XCTAssertNil(plan)
    }

    /// A user's start of an iCloud Drive album's move runs the album step instead
    /// of the whole-album move: the album gets its CloudKit album and flips, no
    /// media moves, the files stay in the folder, no whole-album plan is written,
    /// and the prepared album is handed to the blob migration.
    func testUserStartRoutesToNewFlow() async throws {
        let drive = try await makeDriveAlbum(count: 2)
        let before = try mediaSnapshot(drive)
        let store = self.store!
        let manager = CloudKitMigrationManager(albumManager: albumManager,
                                               storeFactory: { _ in store },
                                               materializer: FakeICloudDriveMaterializer(),
                                               makeICloudDriveAlbumMigration: { [unowned self] _ in self.makeMigration() })

        let claimed = await manager.start(album: drive.album, trigger: .user)

        XCTAssertTrue(claimed)
        XCTAssertEqual(manager.state, .completed)
        guard case .present(let marker) = markerFile(in: drive) else { return XCTFail("expected a marker file") }
        let albumID = marker.albumID
        touchedAlbumIDs.insert(albumID)
        XCTAssertEqual(manager.destinationAlbum?.albumID, albumID)
        XCTAssertEqual(manager.destinationAlbum?.storageOption, .cloudKit)
        XCTAssertEqual(store.savedAlbumCalls.map(\.albumID), [albumID])
        XCTAssertTrue(store.uploadCalls.isEmpty, "no media moves")
        XCTAssertEqual(try mediaSnapshot(drive), before, "every file stays in the folder")
        let wholeAlbumPlan = await MigrationPlanStore(album: drive.album).load()
        XCTAssertNil(wholeAlbumPlan, "no whole-album move is planned")
        let albumPlan = await plan(drive, albumID: albumID)
        XCTAssertEqual(Set(albumPlan?.items.map(\.mediaID) ?? []), Set(drive.mediaIDs))
        XCTAssertEqual(listed(drive, in: albumManager.fetchAlbumsFromSources(includingHidden: true)), [.cloudKit])
        XCTAssertEqual(blobMigrationStarts, [BlobMigrationStart(albumID: albumID, folder: drive.folder)])
        XCTAssertFalse(CloudKitMigrationManager.isActive(albumID: drive.album.id), "the album is released")
    }
}

private final class WiFiFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
