//
//  CloudKitFileAccessTests.swift
//  EncameraCoreTests
//
//  Chunk 04 — the CloudKit FileAccess branch, exercised against a mock store
//  behind a real coordinator. Encryption is the existing V2 path; only transport
//  is CloudKit. No network, no iCloud account.
//

import XCTest
import CloudKit
import UIKit
@testable import EncameraCore

final class CloudKitFileAccessTests: XCTestCase {

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FileLoadingStatus] = []
        var values: [FileLoadingStatus] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ s: FileLoadingStatus) { lock.lock(); storage.append(s); lock.unlock() }
    }

    private static func tinyPNG() -> Data {
        let size = CGSize(width: 2, height: 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }

    private func makeAlbum(name: String = "Vacation-\(UUID().uuidString)", storage: StorageType = .cloudKit) -> Album {
        let key = PrivateKey(name: "test-key", keyBytes: Array(repeating: UInt8(9), count: 32), creationDate: Date())
        return Album(name: name, storageOption: storage, creationDate: Date(), key: key)
    }

    private func makeAccess(album: Album, store: MockCloudKitMediaStore) async -> CloudKitFileAccess {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        return await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)
    }

    private func photo(id: String = UUID().uuidString, data: Data) throws -> InteractableMedia<CleartextMedia> {
        let media = CleartextMedia(source: .data(data), mediaType: .photo, id: id)
        return try InteractableMedia(underlyingMedia: [media])
    }

    private func encURL(for album: Album, id: String) -> URL {
        CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .photo)
    }

    /// Produce a valid ENC2 ciphertext for `data` so a load can be tested as a
    /// pure cloud fetch (no prior local save that would warm the coordinator cache).
    private func makeENC2(album: Album, id: String, data: Data) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        let cleartext = CleartextMedia(source: .data(data), mediaType: .photo, id: id)
        let handler = SecretFileHandlerV2(keyBytes: album.key.keyBytes, source: cleartext, targetURL: tmp)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }

    // MARK: - Save

    func testSaveEncryptsThenUploads() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("super secret cleartext".utf8)
        _ = try await access.save(media: photo(id: id, data: cleartext), metadata: nil, progress: { _ in })

        XCTAssertEqual(store.uploadCalls, [id])
        let upload = try XCTUnwrap(store.uploadedItems.first)

        // Uploaded bytes are ciphertext: the on-disk file is an ENC2 file.
        let bytes = try Data(contentsOf: upload.encryptedFileURL)
        XCTAssertEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic, "Uploaded file must be ENC2 ciphertext")
        XCTAssertFalse(bytes.contains(Data("super secret cleartext".utf8)), "No plaintext may appear in the uploaded file")

        // albumID is the keyed hash, not the cleartext album name.
        XCTAssertNotEqual(upload.albumID, album.name)
        XCTAssertEqual(upload.albumID, SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes))

        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    // MARK: - Load

    func testLoadFetchesLazilyThenDecrypts() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("decrypt round trip".utf8)
        // The blob exists only in the cloud (never saved locally) -> first load fetches.
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])

        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)
        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)

        // Second load is served from the now-local copy — no duplicate fetch.
        _ = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1, "Second load must not re-fetch")

        try? FileManager.default.removeItem(at: localURL)
    }

    func testProgressMapsDownloadThenDecrypt() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        store.blobContents = try await makeENC2(album: album, id: id, data: Data("progress".utf8))

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])

        let box = StatusBox()
        _ = try await access.loadMedia(media: encrypted, progress: { box.append($0) })

        let kinds = box.values.map { status -> String in
            switch status {
            case .downloading: return "downloading"
            case .decrypting: return "decrypting"
            case .loaded: return "loaded"
            case .notLoaded: return "notLoaded"
            }
        }
        XCTAssertTrue(kinds.contains("downloading"))
        XCTAssertTrue(kinds.contains("decrypting"))
        XCTAssertEqual(kinds.last, "loaded")
        // Ordering: a download status precedes a decrypt status.
        if let d = kinds.firstIndex(of: "downloading"), let c = kinds.firstIndex(of: "decrypting") {
            XCTAssertLessThan(d, c)
        } else {
            XCTFail("Expected both downloading and decrypting statuses")
        }
        try? FileManager.default.removeItem(at: localURL)
    }

    // MARK: - Enumeration

    func testEnumerateReadsFromSyncedIndexNotNetwork() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.fetchBlobError = CKErrorFactory.error(.networkUnavailable)  // any direct fetch would fail
        let albumIDHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        store.changeSet = CloudKitChangeSet(
            changed: [
                CloudKitMediaMetadata(recordName: "m1", albumID: albumIDHash, mediaID: "m1", mediaType: .photo,
                                      createdAt: Date(timeIntervalSince1970: 200), sizeBytes: 1, creationDeviceID: "d",
                                      deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1"),
                CloudKitMediaMetadata(recordName: "m2", albumID: albumIDHash, mediaID: "m2", mediaType: .photo,
                                      createdAt: Date(timeIntervalSince1970: 100), sizeBytes: 1, creationDeviceID: "d",
                                      deletedAt: nil, schemaVersion: 1, recordChangeTag: "t2")
            ],
            deleted: [], token: nil, moreComing: false
        )
        let access = await makeAccess(album: album, store: store)

        _ = await access.reconcile()
        let media = await access.enumerate()

        XCTAssertEqual(Set(media.map { $0.id }), ["m1", "m2"])
        XCTAssertEqual(store.fetchBlobCount, 0, "Enumeration must not hit the network")
    }

    // MARK: - Delete

    func testDeleteRoutesToCoordinatorRemove() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "m1")), mediaType: .photo, id: "m1")
        ])
        try await access.delete(media: [encrypted])

        // Delete tombstones first (cross-device propagation), addressing the
        // component record — "m1#0" for the photo component.
        XCTAssertEqual(store.tombstoneCalls, [CloudKitFileAccess.componentRecordName(mediaID: "m1", type: .photo)])
    }

    // MARK: - Availability / regression guards

    func testCloudKitUnavailableWhenFlagOff() {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }

        let availability = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .cloudKit)
        guard case .unavailable = availability else {
            return XCTFail("cloudKit must be unavailable when the flag is off")
        }
    }

    func testLocalAndICloudModelsUnchanged() {
        // Regression guard for hard requirement #1: the existing storage planes are untouched.
        XCTAssertTrue(StorageType.local.modelForType == LocalStorageModel.self)
        XCTAssertTrue(StorageType.icloud.modelForType == iCloudStorageModel.self)
        XCTAssertTrue(StorageType.cloudKit.modelForType == CloudKitStorageModel.self)
        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .local), .available)
    }

    // MARK: - Bugbot regressions

    func testLivePhotoUploadsTwoDistinctRecords() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let photoPart = CleartextMedia(source: .data(Data("photo".utf8)), mediaType: .photo, id: id)
        let videoPart = CleartextMedia(source: .data(Data("video".utf8)), mediaType: .video, id: id)
        let live = try InteractableMedia(underlyingMedia: [photoPart, videoPart])
        XCTAssertEqual(live.mediaType, .livePhoto)

        _ = try await access.save(media: live, metadata: nil, progress: { _ in })

        XCTAssertEqual(store.uploadedItems.count, 2)
        let recordNames = Set(store.uploadedItems.map { $0.recordName })
        XCTAssertEqual(recordNames.count, 2, "Each Live Photo component must be its own CloudKit record")
        XCTAssertEqual(Set(store.uploadedItems.map { $0.mediaID }), [id], "Both components share the grouping id")

        for type in [MediaType.photo, .video] {
            try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: type))
        }
    }

    func testCloudKitAlbumRoutesToCloudEvenWhenFlagOff() async throws {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        let shared = InMemoryCloudKitMediaStore()
        let previousProvider = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer {
            FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled)
            CloudKitStoreProvider.makeStore = previousProvider
        }

        let album = makeAlbum()   // .cloudKit
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

        let id = UUID().uuidString
        // Real image bytes so DiskFileAccess.createPreview wouldn't throw — the test
        // must fail on routing, not thumbnail generation, before the fix.
        let imageData = Self.tinyPNG()
        let photo = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(imageData), mediaType: .photo, id: id)
        ])
        _ = try await access.save(media: photo, metadata: nil, progress: { _ in })

        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        let metadata = try await shared.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(metadata.count, 1, "A .cloudKit album must use CloudKit even when the flag is off")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .photo))
    }

    func testEnumerateWithMetadataReadsFromIndexNotNetwork() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.fetchBlobError = CKErrorFactory.error(.networkUnavailable)
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m1", albumID: albumHash, mediaID: "m1", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 300), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1"),
            CloudKitMediaMetadata(recordName: "m2", albumID: albumHash, mediaID: "m2", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 200), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t2")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)

        _ = await access.reconcile()
        let result = await access.enumerateMediaWithMetadata(sortBy: .dateEncrypted(ascending: false), filterBy: .all)

        XCTAssertEqual(Set(result.map { $0.media.id }), ["m1", "m2"])
        XCTAssertEqual(store.fetchBlobCount, 0, "Metadata enumeration must not hit the network")
    }

    func testDeleteAllTombstonesEveryCloudKitRecord() async throws {
        let album = makeAlbum()
        let store = InMemoryCloudKitMediaStore()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)

        for _ in 0..<2 {
            let id = UUID().uuidString
            let photo = try InteractableMedia(underlyingMedia: [
                CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
            ])
            _ = try await access.save(media: photo, metadata: nil, progress: { _ in })
        }

        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        let before = try await store.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(before.count, 2)

        try await access.deleteAllMedia()

        let after = try await store.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(after.count, 0, "deleteAll must remove every CloudKit record for the album")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
    }

    func testSaveEnsuresZoneBeforeUpload() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: try photo(id: id, data: Data("zone".utf8)), metadata: nil, progress: { _ in })

        XCTAssertGreaterThanOrEqual(store.ensureZoneCalls, 1, "Save must ensure the zone exists before uploading")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testLoadRefetchesWhenChangeTagAdvances() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!

        func meta(tag: String) -> CloudKitMediaMetadata {
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumHash, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: tag)
        }
        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "m")), mediaType: .photo, id: "m")
        ])

        // v1 at tag t1
        store.changeSet = CloudKitChangeSet(changed: [meta(tag: "t1")], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("v1".utf8))
        let first = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(first.underlyingMedia.first?.data, Data("v1".utf8))
        XCTAssertEqual(store.fetchBlobCount, 1)

        // A remote re-upload advances the tag to t2 with new content.
        store.changeSet = CloudKitChangeSet(changed: [meta(tag: "t2")], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("v2".utf8))
        let second = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(second.underlyingMedia.first?.data, Data("v2".utf8), "Stale tag must trigger a refetch")
        XCTAssertEqual(store.fetchBlobCount, 2)
    }

    func testSaveRecreatesZoneOnZoneNotFound() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.uploadErrorOnce = CloudKitMediaStoreError.zoneNotFound
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: try photo(id: id, data: Data("z".utf8)), metadata: nil, progress: { _ in })

        XCTAssertEqual(store.recreateZoneCount, 1, "A zoneNotFound upload must recreate the zone")
        XCTAssertEqual(store.uploadCalls.count, 2, "Upload should retry once after recreating the zone")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testStorageModelFolderMatchesBlobCacheKey() {
        let album = makeAlbum()
        let albumID = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        let expected = CloudKitBlobCache.albumFolderName(albumID)
        let baseURL = CloudKitStorageModel(album: album).baseURL
        XCTAssertEqual(baseURL.lastPathComponent, expected,
                       "Storage model folder must match the blob cache's per-album key")
        XCTAssertEqual(baseURL.deletingLastPathComponent().standardizedFileURL.path,
                       CloudKitBlobCache.defaultBaseDir.standardizedFileURL.path)
        try? FileManager.default.removeItem(at: baseURL)
    }

    func testEntryCountForCloudKitAlbumReadsIndex() async throws {
        let album = makeAlbum()
        let indexStore = MediaIndexStore(album: album)
        let entries = ["a", "b", "c"].map {
            MediaIndexEntry(id: $0, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: Date(), dateTaken: Date(), subtypeRawValue: 0)
        }
        try await indexStore.save(MediaIndex(entries: entries))
        defer { try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album)) }

        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 3,
                       "CloudKit album count must come from the synced index, not on-disk files")
    }

    func testBlobCacheIndexSurvivesRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ckcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).bin")
        try Data("ciphertext".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let cache1 = CloudKitBlobCache(baseDir: dir)
        _ = try await cache1.store(recordName: "rec#0", changeTag: "t1", albumID: "albumHash", from: src)

        // A fresh instance (app relaunch) over the same directory must recover the
        // cached entry instead of re-downloading and leaking the orphan.
        let cache2 = CloudKitBlobCache(baseDir: dir)
        let url = await cache2.cachedURL(recordName: "rec#0", changeTag: "t1")
        XCTAssertNotNil(url, "Cache index should be restored from disk on init")
    }

    func testSaveOmitsThumbnailWhenPreviewMissing() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        // Non-image bytes => preview generation fails => no preview file on disk.
        _ = try await access.save(media: try photo(id: id, data: Data("not an image".utf8)), metadata: nil, progress: { _ in })

        let upload = try XCTUnwrap(store.uploadedItems.first)
        XCTAssertNil(upload.encryptedThumbURL, "A missing preview must not be uploaded as a thumbnail asset")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testCloudKitAlbumsSyncReconcilesInactiveAlbums() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]

        // Upload a photo so the cloud has a record for this album.
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: shared)
        let id = UUID().uuidString
        _ = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })

        // Simulate a device that hasn't built this album's index yet.
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 0)

        // The fan-out sync must rebuild it without the album being "active".
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false)
        await sync.syncAll()

        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 1, "syncAll must reconcile inactive CloudKit albums")
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    /// The delete path must NOT be gated on the `cloudKitStorage` flag:
    /// `CloudKitAlbumsSync` keeps reconciling existing `.cloudKit` albums with the
    /// flag off, so a flag-gated delete would enqueue no tombstone and the reconciler
    /// would resurrect the album on the very device that deleted it.
    func testDeleteTombstonesCloudKitRecordEvenWhenFlagOff() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }

        let album = makeAlbum()
        let hash = try XCTUnwrap(SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes))
        try await shared.saveAlbum(CloudKitAlbumUpload(albumID: hash,
                                                       encName: album.encryptedPathComponent,
                                                       createdAt: album.creationDate,
                                                       isHidden: false))

        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        albumManager.delete(album: album)
        defer { CloudKitAlbumTombstoneQueue().remove(hash) }

        // The tombstone save is fire-and-forget; wait for it to land in the store.
        for _ in 0..<100 {
            if let record = try await shared.fetchAllAlbums().first(where: { $0.albumID == hash }),
               record.deletedAt != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let record = try await shared.fetchAllAlbums().first { $0.albumID == hash }
        XCTAssertNotNil(record?.deletedAt,
                        "Deleting a .cloudKit album with the flag off must still tombstone its EncAlbum record")
    }

    /// A `syncAll` that joins an in-flight run may have missed the fetch/reconcile
    /// already past — the join must flag a re-run so the change it carries is honored
    /// by one extra pass instead of silently dropped until the next trigger.
    func testSyncAllJoinerMidRunTriggersExtraPass() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let released = Flag()
        let store = MockCloudKitMediaStore()
        store.fetchAllAlbumsGate = { while !released.isSet() { await Task.yield() } }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]

        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in InMemoryCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = prev }

        let suite = "test.cloudkit.albumssync.join"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false) { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    tombstoneQueue: CloudKitAlbumTombstoneQueue(defaults: UserDefaults(suiteName: suite)!))
        }

        let first = Task { await sync.syncAll() }
        while store.fetchAllAlbumsCount < 1 { await Task.yield() }   // first pass is mid-run, held by the gate

        let second = Task { await sync.syncAll() }                    // joins the in-flight run
        while !(await sync.resyncRequested) { await Task.yield() }    // the join has been recorded
        released.set()

        await first.value
        await second.value
        XCTAssertEqual(store.fetchAllAlbumsCount, 2,
                       "A syncAll joining mid-run must be honored by exactly one extra pass")
    }

    func testMaterializedSourceUsesCacheRecordPath() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumHash, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)
        _ = await access.reconcile()

        let media = await access.enumerate()
        let source = media.first?.underlyingMedia.first?.source
        guard case .url(let url)? = source else { return XCTFail("Expected a url source") }
        // Must point at the cache/record-name path so a lazily downloaded blob resolves.
        XCTAssertEqual(url.lastPathComponent, CloudKitFileAccess.componentRecordName(mediaID: "m", type: .photo))
    }

    func testCloudKitMediaPageUsesCacheRecordPath() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

        let id = UUID().uuidString
        _ = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })

        let page = await access.mediaPage(sortBy: .dateEncrypted(ascending: false), filterBy: .all, offset: 0, pageSize: 10)
        let source = page.media.first?.underlyingMedia.first?.source
        guard case .url(let url)? = source else { return XCTFail("Expected a url source") }
        XCTAssertEqual(url.lastPathComponent, CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo),
                       "mediaPage must materialize CloudKit media at the cache record path")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    func testFailedThumbnailFetchDoesNotCacheTag() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let albumHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)!
        // A synced item gives a non-nil current change tag for "p#0".
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "p#0", albumID: albumHash, mediaID: "p", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  deletedAt: nil, schemaVersion: 1, recordChangeTag: "t1")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)
        _ = await access.reconcile()

        // The fetch writes a (partial) file then fails — so the file exists but is bad.
        store.fetchThumbnailWritesFile = true
        store.fetchThumbnailError = CloudKitMediaStoreError.notFound

        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "p")), mediaType: .photo, id: "p")
        ])
        for _ in 0..<2 {
            _ = try? await access.loadMediaPreview(for: media)
        }

        XCTAssertEqual(store.fetchThumbnailCount, 2, "A failed thumbnail fetch must be retried, not recorded as current")
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    func testCloudKitAlbumIsDiscoverable() throws {
        let key = PrivateKey(name: "disc-key", keyBytes: Array(repeating: UInt8(5), count: 32), creationDate: Date())
        let name = "CKDisc-\(UUID().uuidString)"
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key)

        // Place the discovery marker the way album creation does.
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marker) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertTrue(albums.contains { $0.storageOption == .cloudKit && $0.name == name },
                      "A CloudKit album marker must be discoverable in the album list")
    }

    func testStorageTypeCodableRoundTripsCloudKit() throws {
        let data = try JSONEncoder().encode(StorageType.cloudKit)
        let decoded = try JSONDecoder().decode(StorageType.self, from: data)
        XCTAssertEqual(decoded, .cloudKit)

        let album = makeAlbum()
        let albumData = try JSONEncoder().encode(album)
        let decodedAlbum = try JSONDecoder().decode(Album.self, from: albumData)
        XCTAssertEqual(decodedAlbum.storageOption, .cloudKit)
    }
}
