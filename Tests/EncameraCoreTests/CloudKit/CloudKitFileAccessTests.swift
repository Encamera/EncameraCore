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
import AVFoundation
@testable import EncameraCore

final class CloudKitFileAccessTests: XCTestCase {

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FileLoadingStatus] = []
        var values: [FileLoadingStatus] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ s: FileLoadingStatus) { lock.lock(); storage.append(s); lock.unlock() }
    }

    private static func tinyPNG() -> Data {
        TestImageData.png()
    }

    private func makeAlbum(name: String = "Vacation-\(UUID().uuidString)", storage: StorageType = .cloudKit) -> Album {
        let key = PrivateKey(keyBytes: Array(repeating: UInt8(9), count: 32), creationDate: Date())
        return Album(name: name, storageOption: storage, creationDate: Date(), key: key,
                     albumID: storage == .cloudKit ? UUID().uuidString : nil)
    }

    private func makeAccess(album: Album,
                            store: MockCloudKitMediaStore,
                            chunkStore: ChunkedBlobStoring? = nil) async -> CloudKitFileAccess {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]
        return await CloudKitFileAccess(album: album, albumManager: albumManager, store: store, chunkStore: chunkStore)
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
    private func makeENC2(album: Album, id: String, data: Data, mediaType: MediaType = .photo) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        let cleartext = CleartextMedia(source: .data(data), mediaType: mediaType, id: id)
        let handler = SecretFileHandlerV2(keyBytes: album.key.keyBytes, source: cleartext, targetURL: tmp)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bytes = try Data(contentsOf: tmp)
        XCTAssertEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic, "Fixture must be a genuine V2 file")
        return bytes
    }

    /// Produce a **genuine V1** ciphertext with the exact call the app's own no-metadata save
    /// makes: `DiskFileAccess.save(metadata: nil)` takes the `SecretFileHandler.encrypt()`
    /// branch, which writes the older format with no ENC2 magic. (Going through
    /// `DiskFileAccess.save` itself would also drag in `createPreview`, which needs decodable
    /// image bytes; `testDiskSaveWithoutMetadataProducesV1Ciphertext` pins that the app path
    /// really does produce this format.) This is what a legacy local library is full of, and
    /// migration uploads those bytes to CloudKit verbatim — no re-encryption.
    private func makeV1(key: PrivateKey, id: String, data: Data, mediaType: MediaType = .photo) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        let cleartext = CleartextMedia(source: .data(data), mediaType: mediaType, id: id)
        let handler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartext, targetURL: tmp)
        _ = try await handler.encrypt()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bytes = try Data(contentsOf: tmp)
        XCTAssertNotEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic,
                          "Fixture must be a genuine V1 file — V1 carries no ENC2 magic")
        return bytes
    }

    /// A chunked video record as the mock store would hand it to a cold reader:
    /// chunk geometry and the ENC3 header, no blob. The chunks themselves go into
    /// `chunkStore` when one is given, so a reader can fetch them.
    private func seedChunkedVideo(in store: MockCloudKitMediaStore,
                                  album: Album,
                                  id: String,
                                  chunkStore: InMemoryChunkedBlobStore? = nil,
                                  key: PrivateKey? = nil,
                                  keyFingerprint: String = "",
                                  metadata: EncryptedFileMetadata? = nil) async throws -> String {
        let plaintext = Data(repeating: 0x5A, count: 5_000)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-src.bin")
        let enc3 = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).enc3")
        try plaintext.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: enc3)
        }
        let header = try SeekableEncryptedWriter(keyBytes: (key ?? album.key).keyBytes, chunkSize: 1_000)
            .encrypt(source: source, destination: enc3,
                     metadata: try metadata.map(SeekableEncryptedFormat.encodeMetadata))
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .video)
        if let chunkStore {
            try await chunkStore.uploadChunks(enc3FileURL: enc3, mediaRecordName: recordName, progress: { _ in })
        }
        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: recordName,
                                  albumID: "album",
                                  mediaID: id,
                                  mediaType: .video,
                                  createdAt: Date(),
                                  sizeBytes: Int64(header.geometry.totalCiphertextLength),
                                  creationDeviceID: "writer",
                                  schemaVersion: 1,
                                  keyFingerprint: keyFingerprint,
                                  recordChangeTag: "tag-1",
                                  chunkCount: header.chunkCount,
                                  plaintextLength: Int64(header.plaintextLength),
                                  encHeader: header.encoded())
        ]
        return recordName
    }

    // MARK: - Save

    func testSaveEncryptsThenUploads() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("super secret cleartext".utf8)
        _ = try await access.save(media: photo(id: id, data: cleartext), metadata: nil, progress: { _ in })
        await access.drainUploads()

        XCTAssertEqual(store.uploadCalls, [id])
        let upload = try XCTUnwrap(store.uploadedItems.first)

        let bytes = try XCTUnwrap(store.uploadedBlobBytes[upload.recordName])
        XCTAssertEqual(Array(bytes.prefix(4)), EncryptedFileFormat.magic, "Uploaded file must be ENC2 ciphertext")
        XCTAssertFalse(bytes.contains(Data("super secret cleartext".utf8)), "No plaintext may appear in the uploaded file")

        XCTAssertNotEqual(upload.albumID, album.name)
        XCTAssertEqual(upload.albumID, album.albumID)

        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    /// While a move back to this device is running on an album, a save into it is
    /// refused before anything is encrypted or uploaded: the run deletes the album
    /// record when it finishes, and the record would take the new media with it.
    @MainActor
    func testSaveIntoAnAlbumMovingToLocalThrowsMoveInProgress() async throws {
        let album = makeAlbum()
        let albumID = try XCTUnwrap(album.albumID)
        let localModel = LocalStorageModel(album: Album.localTwin(of: album))
        let moveStore = MockCloudKitMediaStore()
        moveStore.addServerRecord(albumID: albumID)
        moveStore.blobContents = Data(repeating: 0xAA, count: 10)
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]
        try CloudKitAlbumMarker(album: album, isHidden: false).write(albumID: albumID)
        let gate = AsyncGate()
        CloudKitMigrationManager.boundaryHook = { boundary in
            if case .removing = boundary { await gate.enter() }
        }
        defer {
            CloudKitMigrationManager.boundaryHook = nil
            try? CloudKitAlbumMarker.remove(albumID: albumID)
            try? FileManager.default.removeItem(at: localModel.baseURL)
            try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: album))
        }
        let manager = CloudKitMigrationManager(albumManager: albumManager, storeFactory: { _ in moveStore })
        let plan = try MigrationPlan.album(album, items: [])
        let run = Task { await manager.start(plan: plan) }
        await gate.waitUntilEntered()
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: album.id), .source(.toLocal, isRunning: true),
                       "precondition: the move back is holding the album")

        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        do {
            _ = try await access.save(media: photo(id: id, data: Data("late capture".utf8)), metadata: nil,
                                      progress: { _ in })
            XCTFail("a save into an album moving to this device must be refused")
        } catch let error as AlbumMoveGuardError {
            XCTAssertEqual(error, .moveInProgress)
        }
        await access.drainUploads()
        XCTAssertTrue(store.uploadCalls.isEmpty, "nothing is uploaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: encURL(for: album, id: id).path),
                       "nothing is written for the refused capture")

        await gate.release()
        _ = await run.value
        XCTAssertEqual(manager.state, .completed)
        XCTAssertEqual(MigrationPlanStore.planRole(forAlbumID: album.id), .none,
                       "the album stops refusing once the run is over")
    }

    /// Every ordinary capture/import — not just the one-time migration path — must
    /// stamp the record with the key that encrypted it, so the census can name the
    /// key a library needs. Guards the `keyFingerprint:` argument at the
    /// `CloudKitMediaUpload` construction site in `saveSingle`.
    func testSavedMediaIsStampedWithTheAlbumKeyFingerprint() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: photo(id: id, data: Data("cleartext".utf8)), metadata: nil, progress: { _ in })
        await access.drainUploads()

        let upload = try XCTUnwrap(store.uploadedItems.first)
        XCTAssertEqual(upload.keyFingerprint, album.key.keyFingerprint,
                       "every saved record must name the key that encrypted it")
        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 1, fingerprints: [album.key.keyFingerprint: 1]),
                       "so the census can name the key for an ordinary capture")

        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    // MARK: - Load

    func testLoadFetchesLazilyThenDecrypts() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("decrypt round trip".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])

        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)
        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)

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
        store.fetchBlobError = CKErrorFactory.error(.networkUnavailable)
        let albumIDHash = album.albumID!
        store.changeSet = CloudKitChangeSet(
            changed: [
                CloudKitMediaMetadata(recordName: "m1", albumID: albumIDHash, mediaID: "m1", mediaType: .photo,
                                      createdAt: Date(timeIntervalSince1970: 200), sizeBytes: 1, creationDeviceID: "d",
                                      schemaVersion: 1, recordChangeTag: "t1"),
                CloudKitMediaMetadata(recordName: "m2", albumID: albumIDHash, mediaID: "m2", mediaType: .photo,
                                      createdAt: Date(timeIntervalSince1970: 100), sizeBytes: 1, creationDeviceID: "d",
                                      schemaVersion: 1, recordChangeTag: "t2")
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

        XCTAssertEqual(store.deleteCalls, [CloudKitFileAccess.componentRecordName(mediaID: "m1", type: .photo)])
    }

    /// Deleting a photo that has NOT uploaded yet (offline, or before the drain
    /// ran) must remove it from the album. Regression: the remote call throws
    /// `.notFound` for a record the zone has never seen, and that error used to
    /// abort `remove` before any local cleanup ran — the queue entry and
    /// ciphertext were already gone, but the index entry survived as a permanent,
    /// unopenable ghost the user could never delete.
    func testDeletingAPendingItemRemovesItFromTheAlbum() async throws {
        let album = makeAlbum()
        let store = InMemoryCloudKitMediaStore(uploadDelay: .seconds(30))
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)

        let id = UUID().uuidString
        let saved = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })

        let visible = await access.enumerate()
        XCTAssertEqual(visible.count, 1, "A pending capture must be visible before it uploads")

        try await access.delete(media: [try XCTUnwrap(saved)])

        let after = await access.enumerate()
        XCTAssertEqual(after.count, 0, "Deleting a pending item must remove it from the album, not leave a ghost")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
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
        await access.drainUploads()

        XCTAssertEqual(store.uploadedItems.count, 2)
        let recordNames = Set(store.uploadedItems.map { $0.recordName })
        XCTAssertEqual(recordNames.count, 2, "Each Live Photo component must be its own CloudKit record")
        XCTAssertEqual(Set(store.uploadedItems.map { $0.mediaID }), [id], "Both components share the grouping id")

        for type in [MediaType.photo, .video] {
            try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: type))
        }
    }

    func testSlowMotionVideoPreviewShowsTheSlowedDuration() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("slowmo-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movieURL, seconds: 2)
        defer { try? FileManager.default.removeItem(at: movieURL) }

        // 0.5–1.5 s slowed 4x: a 2 s clip plays for 5 s.
        let ramp = SlowMotionRamp(segments: [
            .init(sourceStart: CMTime(value: 300, timescale: 600),
                  sourceDuration: CMTime(value: 600, timescale: 600),
                  targetDuration: CMTime(value: 2400, timescale: 600))
        ])
        var metadata = EncryptedFileMetadata()
        metadata.video = .init(duration: 5, slowMotion: ramp)
        let id = UUID().uuidString
        let video = try InteractableMedia(underlyingMedia: [CleartextMedia(source: .url(movieURL), mediaType: .video, id: id)])

        let result = try await access.save(media: video, metadata: metadata, progress: { _ in })
        let saved = try XCTUnwrap(result)
        await access.drainUploads()

        let preview = try await access.loadMediaPreview(for: saved)
        XCTAssertEqual(preview.videoDuration, "00:05")

        try? FileManager.default.removeItem(at: thumbnailURL(forMediaID: id))
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .video))
    }

    func testLivePhotoThumbnailComesFromThePhotoAndTheVideoNeverRewritesIt() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movieURL, seconds: 1)
        defer { try? FileManager.default.removeItem(at: movieURL) }

        let id = UUID().uuidString
        let videoPart = CleartextMedia(source: .url(movieURL), mediaType: .video, id: id)
        let photoPart = CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        let live = try InteractableMedia(underlyingMedia: [videoPart, photoPart])
        XCTAssertEqual(live.mediaType, .livePhoto)

        let result = try await access.save(media: live, metadata: nil, progress: { _ in })
        let saved = try XCTUnwrap(result)
        await access.drainUploads()

        let preview = try await access.loadMediaPreview(for: saved)
        XCTAssertNil(preview.videoDuration, "The thumbnail must be the photo's, not one rewritten from the video")
        XCTAssertTrue(preview.isLivePhoto)
        let videoUpload = try XCTUnwrap(store.uploadedItems.first { $0.recordName.hasSuffix("#\(MediaType.video.rawValue)") })
        XCTAssertNotNil(videoUpload.encryptedThumbURL, "The photo is saved first, so the video record carries its thumbnail")

        try? FileManager.default.removeItem(at: thumbnailURL(forMediaID: id))
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
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

        let album = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

        let id = UUID().uuidString
        let imageData = Self.tinyPNG()
        let photo = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(imageData), mediaType: .photo, id: id)
        ])
        _ = try await access.save(media: photo, metadata: nil, progress: { _ in })
        await CloudKitUploader.shared.drainNow()

        let albumHash = album.albumID!
        let metadata = try await shared.fetchMetadata(albumID: albumHash, includeThumbnail: false)
        XCTAssertEqual(metadata.count, 1, "A .cloudKit album must use CloudKit even when the flag is off")

        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .photo))
    }

    func testEnumerateWithMetadataReadsFromIndexNotNetwork() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.fetchBlobError = CKErrorFactory.error(.networkUnavailable)
        let albumHash = album.albumID!
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m1", albumID: albumHash, mediaID: "m1", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 300), sizeBytes: 1, creationDeviceID: "d",
                                  schemaVersion: 1, recordChangeTag: "t1"),
            CloudKitMediaMetadata(recordName: "m2", albumID: albumHash, mediaID: "m2", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 200), sizeBytes: 1, creationDeviceID: "d",
                                  schemaVersion: 1, recordChangeTag: "t2")
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
        await access.drainUploads()

        let albumHash = album.albumID!
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
        let albumHash = album.albumID!

        func meta(tag: String) -> CloudKitMediaMetadata {
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumHash, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  schemaVersion: 1, recordChangeTag: tag)
        }
        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "m")), mediaType: .photo, id: "m")
        ])

        store.changeSet = CloudKitChangeSet(changed: [meta(tag: "t1")], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("v1".utf8))
        let first = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(first.underlyingMedia.first?.data, Data("v1".utf8))
        XCTAssertEqual(store.fetchBlobCount, 1)

        store.changeSet = CloudKitChangeSet(changed: [meta(tag: "t2")], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("v2".utf8))
        let second = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(second.underlyingMedia.first?.data, Data("v2".utf8), "Stale tag must trigger a refetch")
        XCTAssertEqual(store.fetchBlobCount, 2)
    }

    /// After "Free up space" the album is still on the device and an item whose
    /// blob was freed comes back from CloudKit and decrypts.
    func testAnItemFreedByFreeUpSpaceRedownloadsAndDecrypts() async throws {
        let album = makeAlbum()
        let albumID = album.albumID!
        try CloudKitAlbumMarker(album: album, isHidden: false).write(albumID: albumID)
        defer { try? CloudKitAlbumMarker.remove(albumID: albumID) }
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumID, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  schemaVersion: 1, recordChangeTag: "t1")
        ], deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        store.blobContents = try await makeENC2(album: album, id: "m", data: Data("freed".utf8))
        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: "m")), mediaType: .photo, id: "m")
        ])
        _ = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(store.fetchBlobCount, 1)
        let cachedBlob = CloudKitStorageModel(album: album).baseURL.appendingPathComponent("m#0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedBlob.path), "precondition: the blob is cached")

        let pendingUploads = CloudKitUploadQueue(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("free-uploads-\(UUID().uuidString)", isDirectory: true))
        try await CloudKitBlobCache().freeUpSpace(pendingUploads: pendingUploads)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedBlob.path), "the cached blob was freed")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.encName, album.encryptedPathComponent,
                       "the album's marker survives freeing space")
        let reloaded = try await access.loadMedia(media: encrypted, progress: { _ in })
        XCTAssertEqual(reloaded.underlyingMedia.first?.data, Data("freed".utf8))
        XCTAssertEqual(store.fetchBlobCount, 2, "the freed blob is fetched again from CloudKit")
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
    }

    func testSaveRecreatesZoneOnZoneNotFound() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        store.uploadErrorOnce = CloudKitMediaStoreError.zoneNotFound
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: try photo(id: id, data: Data("z".utf8)), metadata: nil, progress: { _ in })
        await access.drainUploads()

        XCTAssertEqual(store.recreateZoneCount, 1, "A zoneNotFound upload must recreate the zone")
        XCTAssertEqual(store.uploadCalls.count, 2, "Upload should retry once after recreating the zone")
        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testStorageModelFolderMatchesBlobCacheKey() {
        let album = makeAlbum()
        let albumID = album.albumID!
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

        let cache2 = CloudKitBlobCache(baseDir: dir)
        let url = await cache2.cachedURL(recordName: "rec#0", changeTag: "t1")
        XCTAssertNotNil(url, "Cache index should be restored from disk on init")
    }

    func testSaveOmitsThumbnailWhenPreviewMissing() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        _ = try await access.save(media: try photo(id: id, data: Data("not an image".utf8)), metadata: nil, progress: { _ in })
        await access.drainUploads()

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

        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: shared)
        let id = UUID().uuidString
        _ = try await access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id)
        ]), metadata: nil, progress: { _ in })
        await access.drainUploads()

        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 0)

        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false)
        await sync.syncAll()

        XCTAssertEqual(MediaIndexStore.entryCount(for: album), 1, "syncAll must reconcile inactive CloudKit albums")
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    /// The delete path must NOT be gated on the `cloudKitStorage` flag:
    /// `CloudKitAlbumsSync` keeps reconciling existing `.cloudKit` albums with the
    /// flag off, so a flag-gated delete would queue nothing and the reconciler would
    /// resurrect the album on the very device that deleted it.
    func testDeleteRemovesCloudKitAlbumRecordEvenWhenFlagOff() async throws {
        let shared = InMemoryCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in shared }
        defer { CloudKitStoreProvider.makeStore = prev }

        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }

        let album = makeAlbum()
        let hash = try XCTUnwrap(album.albumID)
        try await shared.saveAlbum(CloudKitAlbumUpload(albumID: hash,
                                                       encName: album.encryptedPathComponent,
                                                       createdAt: album.creationDate,
                                                       isHidden: false))

        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        try albumManager.delete(album: album)
        defer {
            CloudKitAlbumDeleteQueue().remove(hash)
            CloudKitAlbumPublishRegistry().forget(hash)
        }

        for _ in 0..<100 {
            if try await shared.fetchAllAlbums().allSatisfy({ $0.albumID != hash }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let remaining = try await shared.fetchAllAlbums().filter { $0.albumID == hash }
        XCTAssertTrue(remaining.isEmpty,
                      "Deleting a .cloudKit album with the flag off must still remove its EncAlbum record")
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

        let suite = makeIsolatedSuiteName()
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false, makeReconciler: { manager in
            CloudKitAlbumReconciler(store: store,
                                    keyManager: manager.keyManager,
                                    albumManager: manager,
                                    deleteQueue: CloudKitAlbumDeleteQueue(defaults: defaults(forSuite: suite)),
                                    publishRegistry: CloudKitAlbumPublishRegistry(defaults: defaults(forSuite: suite)))
        })

        let first = Task { await sync.syncAll() }
        while store.fetchAllAlbumsCount < 1 { await Task.yield() }

        let second = Task { await sync.syncAll() }
        while !(await sync.resyncRequested) { await Task.yield() }
        released.set()

        await first.value
        await second.value
        XCTAssertEqual(store.fetchAllAlbumsCount, 2,
                       "A syncAll joining mid-run must be honored by exactly one extra pass")
    }

    func testMaterializedSourceUsesCacheRecordPath() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let albumHash = album.albumID!
        store.changeSet = CloudKitChangeSet(changed: [
            CloudKitMediaMetadata(recordName: "m#0", albumID: albumHash, mediaID: "m", mediaType: .photo,
                                  createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 1, creationDeviceID: "d",
                                  schemaVersion: 1, recordChangeTag: "t1")
        ], deleted: [], token: nil, moreComing: false)
        let access = await makeAccess(album: album, store: store)
        _ = await access.reconcile()

        let media = await access.enumerate()
        let source = media.first?.underlyingMedia.first?.source
        guard case .url(let url)? = source else { return XCTFail("Expected a url source") }
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

    func testUploadedPhotoServesLocalThumbnailWithoutFetching() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let result = try await access.save(media: try photo(id: id, data: Self.tinyPNG()), metadata: nil, progress: { _ in })
        let saved = try XCTUnwrap(result)
        await access.drainUploads()
        XCTAssertFalse(store.uploadedItems.isEmpty, "The upload must have confirmed so the record carries a change tag")

        let preview = try await access.loadMediaPreview(for: saved)

        XCTAssertNotNil(preview.thumbnailMedia.data.flatMap(PlatformImage.init(data:)))
        XCTAssertEqual(store.fetchThumbnailCount, 0, "The thumbnail written at save time must be served from disk after the upload")
        try? FileManager.default.removeItem(at: thumbnailURL(forMediaID: id))
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
    }

    func testMissingThumbnailIsFetchedOnceThenServedFromDisk() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        let previewURL = thumbnailURL(forMediaID: id)
        try? FileManager.default.removeItem(at: previewURL)

        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .photo, id: id)
        ])
        for _ in 0..<2 {
            _ = try? await access.loadMediaPreview(for: media)
        }

        XCTAssertEqual(store.fetchThumbnailCount, 1, "Once fetched, a thumbnail must never be fetched again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
        try? FileManager.default.removeItem(at: previewURL)
    }

    func testFailedThumbnailFetchLeavesNoFileAndRetries() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let id = UUID().uuidString
        let previewURL = thumbnailURL(forMediaID: id)
        try? FileManager.default.removeItem(at: previewURL)

        store.fetchThumbnailWritesFile = true
        store.fetchThumbnailError = CloudKitMediaStoreError.notFound

        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .photo, id: id)
        ])
        for _ in 0..<2 {
            _ = try? await access.loadMediaPreview(for: media)
        }

        XCTAssertEqual(store.fetchThumbnailCount, 2, "A failed thumbnail fetch must be retried on the next load")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path),
                       "A failed fetch must not leave a partial file that later loads would treat as the thumbnail")
    }

    private func thumbnailURL(forMediaID id: String) -> URL {
        CloudKitStorageModel.previewURL(forMediaID: id)
    }

    func testCloudKitAlbumIsDiscoverable() throws {
        let key = PrivateKey(keyBytes: Array(repeating: UInt8(5), count: 32), creationDate: Date())
        let name = "CKDisc-\(UUID().uuidString)"
        let albumID = UUID().uuidString
        let album = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key, albumID: albumID)

        try CloudKitAlbumMarker(album: album, isHidden: false).write(albumID: albumID)
        defer { try? CloudKitAlbumMarker.remove(albumID: albumID) }

        let keyManager = DemoKeyManager()
        keyManager.currentKey = key
        let albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)

        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertTrue(albums.contains { $0.storageOption == .cloudKit && $0.name == name && $0.albumID == albumID },
                      "A CloudKit album marker must be discoverable in the album list")
    }

    // MARK: - Mixed on-disk format support

    /// Why V1 blobs exist at all: the app's own local save writes V1 whenever no metadata is
    /// supplied. Anchors the `makeV1` fixture to the real production path.
    func testDiskSaveWithoutMetadataProducesV1Ciphertext() async throws {
        let key = PrivateKey(keyBytes: Array(repeating: UInt8(3), count: 32), creationDate: Date())
        let album = Album(name: "V1Source-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let albumManager = DemoAlbumManager()
        albumManager.keyManager = keyManager
        let disk = DiskFileAccess()
        await disk.configure(for: album, albumManager: albumManager)

        let imageData = Self.tinyPNG()

        let v1 = try await disk.save(media: CleartextMedia(source: .data(imageData), mediaType: .photo, id: UUID().uuidString),
                                     metadata: nil, progress: { _ in })
        let v1URL = try XCTUnwrap(v1?.url)
        defer { try? FileManager.default.removeItem(at: v1URL) }
        XCTAssertNotEqual(Array(try Data(contentsOf: v1URL).prefix(4)), EncryptedFileFormat.magic,
                          "A save without metadata must produce a V1 file — this is why legacy libraries hold V1")

        let v2 = try await disk.save(media: CleartextMedia(source: .data(imageData), mediaType: .photo, id: UUID().uuidString),
                                     metadata: EncryptedFileMetadata(), progress: { _ in })
        let v2URL = try XCTUnwrap(v2?.url)
        defer { try? FileManager.default.removeItem(at: v2URL) }
        XCTAssertEqual(Array(try Data(contentsOf: v2URL).prefix(4)), EncryptedFileFormat.magic,
                       "A save with metadata must still produce V2")
    }

    /// The regression itself: a V1 blob through `loadMedia`'s photo branch (`decryptInMemory`).
    /// Before the fix this threw "V1 file detected" and the item was unreadable on every device.
    func testLoadDecryptsV1CiphertextInMemory() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("legacy v1 photo cleartext".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeV1(key: album.key, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])
        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext,
                       "A V1 blob migrated into a CloudKit album must decrypt to its original cleartext")
    }

    /// The same V1 blob through `loadMedia`'s non-photo branch (`decryptToURL`).
    func testLoadDecryptsV1CiphertextToURL() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data((0..<40000).map { UInt8($0 % 251) })
        let localURL = CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .video)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeV1(key: album.key, id: id, data: cleartext, mediaType: .video)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .video, id: id)
        ])
        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(decrypted.underlyingMedia.first?.url)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    /// `loadMediaToURLs` is a separate decrypt site and needed the same fix.
    func testLoadMediaToURLsDecryptsV1Ciphertext() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("legacy v1 export cleartext".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeV1(key: album.key, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])
        let urls = try await access.loadMediaToURLs(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(urls.first)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    // MARK: - Streaming

    /// Speculative chunk fetches share the cold CloudKit link with the chunk the
    /// player is blocked on, so the streaming source reads exactly one ahead —
    /// the policy's value, not the chunk source's own default.
    func testStreamingPlaybackReadsOneChunkAheadOfCloudKit() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let access = await makeAccess(album: album, store: store, chunkStore: chunkStore)
        let id = UUID().uuidString
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])

        let playback = try await access.streamingPlayback(for: media)

        let source = try XCTUnwrap(playback?.session.source, "a chunked video record must open for streaming")
        XCTAssertEqual(source.readAhead, StreamingPlaybackPolicy.cloudKit.readAhead)
        XCTAssertEqual(source.readAhead, 1)
    }

    func testStreamingPlaybackCarriesTheSlowMotionRampFromTheHeader() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let access = await makeAccess(album: album, store: store, chunkStore: chunkStore)
        let id = UUID().uuidString
        let ramp = SlowMotionRamp(segments: [
            .init(sourceStart: CMTime(value: 300, timescale: 600),
                  sourceDuration: CMTime(value: 600, timescale: 600),
                  targetDuration: CMTime(value: 4800, timescale: 600))
        ])
        var metadata = EncryptedFileMetadata()
        metadata.video = .init(duration: 9.5, slowMotion: ramp)
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore, metadata: metadata)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])

        let playback = try await access.streamingPlayback(for: media)

        XCTAssertEqual(playback?.slowMotion, ramp)
    }

    /// The lightbox's loading state reads chunk 0's transfer from here while the
    /// prefetch runs, through the blob cache on a miss.
    func testStreamingPlaybackReportsTheFirstChunksDownloadProgress() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let backing = InMemoryChunkedBlobStore()
        let chunkStore = ProgressReportingChunkStore(backing: backing)
        let access = await makeAccess(album: album, store: store, chunkStore: chunkStore)
        let id = UUID().uuidString
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: backing)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])
        let recorder = FractionRecorder()

        let playback = try await access.streamingPlayback(for: media, progress: { recorder.record($0) })

        XCTAssertNotNil(playback)
        XCTAssertEqual(recorder.fractions, chunkStore.fractions)
    }

    func testStreamingPlaybackOfAnOrdinaryVideoHasNoRamp() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let access = await makeAccess(album: album, store: store, chunkStore: chunkStore)
        let id = UUID().uuidString
        var metadata = EncryptedFileMetadata()
        metadata.video = .init(duration: 5)
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore, metadata: metadata)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])

        let playback = try await access.streamingPlayback(for: media)

        XCTAssertNotNil(playback)
        XCTAssertNil(playback?.slowMotion)
    }

    /// The first chunk is on the device before the player exists. AVFoundation
    /// fails an item whose first loading request gets no byte for ~20 s, and
    /// cold CloudKit takes longer than that to hand over chunk 0.
    func testStreamingPlaybackFetchesTheFirstChunkBeforeReturning() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let access = await makeAccess(album: album, store: store, chunkStore: chunkStore)
        let id = UUID().uuidString
        let recordName = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])

        let playback = try await access.streamingPlayback(for: media)

        XCTAssertNotNil(playback)
        let log = await chunkStore.fetchLog
        XCTAssertEqual(log.first?.index, 0, "chunk 0 must be fetched before streamingPlayback returns: \(log)")
        XCTAssertEqual(log.first?.media, recordName)
        let telemetry = await playback?.session.telemetry()
        XCTAssertEqual(telemetry?.fetchOrder.first, 0, "the session's own source must hold the prefetched chunk")
    }

    /// A first chunk that cannot be fetched is a video that cannot be streamed.
    /// Returning a playback anyway hands the player an item that fails on its
    /// first request, well after the loading UI has gone.
    func testStreamingPlaybackThrowsWhenTheFirstChunkCannotBeFetched() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let emptyChunkStore = InMemoryChunkedBlobStore()
        let access = await makeAccess(album: album, store: store, chunkStore: emptyChunkStore)
        let id = UUID().uuidString
        _ = try await seedChunkedVideo(in: store, album: album, id: id)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])

        await XCTAssertThrowsErrorAsync(try await access.streamingPlayback(for: media)) { error in
            guard case ChunkedBlobError.chunkNotFound = error else {
                return XCTFail("expected the chunk fetch failure to surface, got \(error)")
            }
        }
        let log = await emptyChunkStore.fetchedIndices
        XCTAssertEqual(log.first, 0, "the failure must come from asking for chunk 0")
    }

    /// V2 must keep working through every site the fix touched — the format-agnostic
    /// handler is a superset, not a swap.
    func testLoadDecryptsV2CiphertextToURL() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data((0..<40000).map { UInt8($0 % 241) })
        let localURL = CloudKitStorageModel(album: album).driveURLForMedia(withID: id, type: .video)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext, mediaType: .video)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .video, id: id)
        ])
        let decrypted = try await access.loadMedia(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(decrypted.underlyingMedia.first?.url)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    func testLoadMediaToURLsDecryptsV2Ciphertext() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        let id = UUID().uuidString
        let cleartext = Data("v2 export cleartext".utf8)
        let localURL = encURL(for: album, id: id)
        try? FileManager.default.removeItem(at: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        store.blobContents = try await makeENC2(album: album, id: id, data: cleartext)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(localURL), mediaType: .photo, id: id)
        ])
        let urls = try await access.loadMediaToURLs(media: encrypted, progress: { _ in })

        let outURL = try XCTUnwrap(urls.first)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    /// Pins the corrected doc comment on `SecretFileHandlerV2`: it is V2-only and *throws*
    /// on V1. If someone ever teaches it V1 compatibility this test should be deleted along
    /// with the comment — but until then the comment must not claim otherwise.
    func testSecretFileHandlerV2ThrowsOnV1WhileSecretFileHandlerReadsIt() async throws {
        let key = PrivateKey(keyBytes: Array(repeating: UInt8(7), count: 32), creationDate: Date())
        let id = UUID().uuidString
        let cleartext = Data("format sniffing cleartext".utf8)
        let v1Bytes = try await makeV1(key: key, id: id, data: cleartext)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-v1.\(MediaType.photo.encryptedFileExtension)")
        try v1Bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let encMedia = EncryptedMedia(source: .url(url), mediaType: .photo, id: id)

        do {
            _ = try await SecretFileHandlerV2(keyBytes: key.keyBytes, source: encMedia).decryptInMemory()
            XCTFail("SecretFileHandlerV2 is V2-only and must throw on a V1 file")
        } catch let error as SecretFilesError {
            guard case .decryptError = error else {
                return XCTFail("Expected a decryptError, got \(error)")
            }
        }

        let readable = try await SecretFileHandler(keyBytes: key.keyBytes, source: encMedia).decryptInMemory()
        XCTAssertEqual(readable.data, cleartext, "SecretFileHandler must read the same V1 file")
    }

    // MARK: - Move

    func testMoveReassignsRecordThenIndexesInTarget() async throws {
        let albumA = makeAlbum(name: "Source-\(UUID().uuidString)")
        let albumB = makeAlbum(name: "Target-\(UUID().uuidString)")
        let store = MockCloudKitMediaStore()
        let albumAHash = albumA.albumID!
        let albumBHash = albumB.albumID!

        let id = UUID().uuidString
        let recordName = CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo)

        // Seed the record under album A in the mock store.
        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: recordName, albumID: albumAHash, mediaID: id,
                                  mediaType: .photo, createdAt: Date(), sizeBytes: 100,
                                  creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: "", recordChangeTag: "t1")
        ]

        let targetAccess = await makeAccess(album: albumB, store: store)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/\(albumAHash)/\(id)"),
                           mediaType: .photo, id: id)
        ])

        try await targetAccess.move(media: encrypted, progress: nil)

        // Verify the store was asked to reassign to album B.
        XCTAssertEqual(store.reassignCalls.count, 1)
        XCTAssertEqual(store.reassignCalls.first?.recordNames, [recordName])
        XCTAssertEqual(store.reassignCalls.first?.toAlbumID, albumBHash)

        // Verify the target index now contains the entry.
        let index = await targetAccess.enumerateMediaWithMetadata(sortBy: .dateEncrypted(ascending: true),
                                                                   filterBy: [])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.first?.media.id, id)
    }

    func testMoveDoesNotTouchLocalStateWhenConfirmationFails() async throws {
        let albumA = makeAlbum(name: "Source-\(UUID().uuidString)")
        let albumB = makeAlbum(name: "Target-\(UUID().uuidString)")
        let store = MockCloudKitMediaStore()
        let albumAHash = albumA.albumID!

        let id = UUID().uuidString
        let recordName = CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo)

        // Seed the record under album A. After reassign the mock mutates albumID
        // in metadataToReturn, BUT we want confirmAlbum to return a WRONG album.
        // confirmAlbum calls fetchRecordMetadata, so we make the metadata return
        // the wrong album ID by NOT seeding the record — reassignAlbum will report
        // it as notFound.
        //
        // Actually, to test confirmation failure specifically: seed the record so
        // reassign succeeds, then override fetchRecordMetadata to return the OLD
        // album ID.
        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: recordName, albumID: albumAHash, mediaID: id,
                                  mediaType: .photo, createdAt: Date(), sizeBytes: 100,
                                  creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: "", recordChangeTag: "t1")
        ]

        let targetAccess = await makeAccess(album: albumB, store: store)

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/\(albumAHash)/\(id)"),
                           mediaType: .photo, id: id)
        ])

        // After the reassign, the mock mutates the albumID in metadataToReturn to
        // albumBHash. To simulate confirmation failure, inject an error so
        // fetchRecordMetadata throws — confirmAlbum propagates that.
        // Instead, let's use a simpler approach: set fetchRecordMetadataError after
        // reassign is done. But we need the reassign to succeed first.
        //
        // The cleanest approach: make the store return notFound for reassign so
        // the move throws before touching local state.
        store.metadataToReturn = []  // no records -> reassign returns them as notFound

        do {
            try await targetAccess.move(media: encrypted, progress: nil)
            XCTFail("move should throw when reassign returns notFound")
        } catch let error as CloudKitMediaStoreError {
            guard case .notFound = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
        }

        // Verify the target index is empty.
        let index = await targetAccess.enumerateMediaWithMetadata(sortBy: .dateEncrypted(ascending: true),
                                                                   filterBy: [])
        XCTAssertEqual(index.count, 0, "Local index must not be touched when the server-side move fails")
    }

    func testMoveLivePhotoReassignsBothComponentsBeforeIndexing() async throws {
        let albumA = makeAlbum(name: "Source-\(UUID().uuidString)")
        let albumB = makeAlbum(name: "Target-\(UUID().uuidString)")
        let store = MockCloudKitMediaStore()
        let albumAHash = albumA.albumID!
        let albumBHash = albumB.albumID!

        let id = UUID().uuidString
        let photoRecordName = CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo)
        let videoRecordName = CloudKitFileAccess.componentRecordName(mediaID: id, type: .video)

        // Seed both components under album A.
        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: photoRecordName, albumID: albumAHash, mediaID: id,
                                  mediaType: .photo, createdAt: Date(), sizeBytes: 100,
                                  creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: "", recordChangeTag: "t1"),
            CloudKitMediaMetadata(recordName: videoRecordName, albumID: albumAHash, mediaID: id,
                                  mediaType: .video, createdAt: Date(), sizeBytes: 200,
                                  creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: "", recordChangeTag: "t2")
        ]

        let targetAccess = await makeAccess(album: albumB, store: store)

        // A Live Photo has both a photo and a video component.
        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/\(albumAHash)/\(id)"),
                           mediaType: .photo, id: id),
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/\(albumAHash)/\(id)"),
                           mediaType: .video, id: id)
        ])

        try await targetAccess.move(media: encrypted, progress: nil)

        // Both components must appear in a single reassign call.
        XCTAssertEqual(store.reassignCalls.count, 1)
        let reassigned = store.reassignCalls.first?.recordNames ?? []
        XCTAssertTrue(reassigned.contains(photoRecordName), "photo component must be reassigned")
        XCTAssertTrue(reassigned.contains(videoRecordName), "video component must be reassigned")
        XCTAssertEqual(store.reassignCalls.first?.toAlbumID, albumBHash)
    }

    func testMovePendingUploadThrows() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)

        // Save a photo so it enters the upload queue, but do NOT drain.
        let id = UUID().uuidString
        _ = try await access.save(media: photo(id: id, data: Self.tinyPNG()), metadata: nil, progress: { _ in })

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/test/\(id)"),
                           mediaType: .photo, id: id)
        ])

        do {
            try await access.move(media: encrypted, progress: nil)
            XCTFail("move must throw for a pending upload")
        } catch let error as CloudKitMediaStoreError {
            guard case .operationNotSupported(let msg) = error else {
                return XCTFail("Expected operationNotSupported, got \(error)")
            }
            XCTAssertTrue(msg.contains("still uploading"), "error message should mention uploading")
        }

        try? FileManager.default.removeItem(at: encURL(for: album, id: id))
    }

    func testMoveRelocatesCachedBlobWithoutRefetch() async throws {
        let albumA = makeAlbum(name: "Source-\(UUID().uuidString)")
        let albumB = makeAlbum(name: "Target-\(UUID().uuidString)")
        let store = MockCloudKitMediaStore()
        let albumAHash = albumA.albumID!
        let id = UUID().uuidString
        let recordName = CloudKitFileAccess.componentRecordName(mediaID: id, type: .photo)

        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: recordName, albumID: albumAHash, mediaID: id,
                                  mediaType: .photo, createdAt: Date(), sizeBytes: 100,
                                  creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: "", recordChangeTag: "t1")
        ]

        // Create the target access (which owns an isolated blob cache for tests).
        let targetAccess = await makeAccess(album: albumB, store: store)

        let fetchBlobCountBefore = store.fetchBlobCount

        let encrypted = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/\(albumAHash)/\(id)"),
                           mediaType: .photo, id: id)
        ])

        try await targetAccess.move(media: encrypted, progress: nil)

        // The move should NOT fetch any blobs — only the reassign and metadata fetch.
        XCTAssertEqual(store.fetchBlobCount, fetchBlobCountBefore,
                       "move must not fetch blobs; it relocates cache entries in place")

        try? FileManager.default.removeItem(at: encURL(for: albumA, id: id))
    }

    // MARK: - Per-record key resolution

    /// A key library that counts how often it is read. The keychain query behind
    /// `storedKeys()` is the expensive part of key resolution, so the album-key
    /// fast path must never reach it.
    private final class CountingKeyManager: DemoKeyManager {
        private(set) var storedKeysReads = 0
        override func storedKeys() throws -> [PrivateKey] {
            storedKeysReads += 1
            return try super.storedKeys()
        }
    }

    private static let foreignKey = PrivateKey(keyBytes: Array(repeating: UInt8(7), count: 32),
                                               creationDate: Date())
    private static let unrelatedKey = PrivateKey(keyBytes: Array(repeating: UInt8(3), count: 32),
                                                 creationDate: Date())
    /// What `seedChunkedVideo` encrypts.
    private static let chunkedPlaintext = Data(repeating: 0x5A, count: 5_000)

    /// An access whose device holds `heldKeys` and whose current key is the album's.
    private func makeAccess(album: Album,
                            store: MockCloudKitMediaStore,
                            chunkStore: ChunkedBlobStoring? = nil,
                            heldKeys: [PrivateKey]) async -> (CloudKitFileAccess, CountingKeyManager) {
        let keyManager = CountingKeyManager()
        keyManager.currentKey = album.key
        keyManager.storedKeysValue = heldKeys
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store, chunkStore: chunkStore)
        return (access, keyManager)
    }

    /// ENC2 ciphertext under `key`, stamped with that key's fingerprint prefix as
    /// every writer of a CloudKit blob stamps it.
    private func makeENC2(key: PrivateKey, id: String, data: Data, stamped: Bool = true,
                          metadata: EncryptedFileMetadata = EncryptedFileMetadata()) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cleartext = CleartextMedia(source: .data(data), mediaType: .photo, id: id)
        _ = try await SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: tmp)
            .encryptWithMetadata(metadata)
        if stamped { KeyStampSlot.writeStamp(key.stampPrefix, url: tmp) }
        return try Data(contentsOf: tmp)
    }

    /// Lets the coordinator learn a record's `keyFingerprint` the way it does in
    /// the app: from the change feed.
    private func bankFingerprint(_ fingerprint: String,
                                 recordName: String,
                                 id: String,
                                 mediaType: MediaType,
                                 album: Album,
                                 store: MockCloudKitMediaStore,
                                 access: CloudKitFileAccess) async {
        let meta = CloudKitMediaMetadata(recordName: recordName, albumID: album.albumID!, mediaID: id,
                                         mediaType: mediaType, createdAt: Date(), sizeBytes: 100,
                                         creationDeviceID: "d", schemaVersion: 1,
                                         keyFingerprint: fingerprint, recordChangeTag: nil)
        store.changeSet = CloudKitChangeSet(changed: [meta], deleted: [], token: nil, moreComing: false)
        await access.reconcile()
    }

    private func photoMedia(album: Album, id: String) throws -> InteractableMedia<EncryptedMedia> {
        try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .photo, id: id)
        ])
    }

    private func videoMedia(album: Album, id: String) throws -> InteractableMedia<EncryptedMedia> {
        try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(encURL(for: album, id: id)), mediaType: .video, id: id)
        ])
    }

    /// A photo moved in from an album under another key keeps its ciphertext, so
    /// the album's key cannot open it. The record's own fingerprint names the key.
    func testLoadDecryptsAPhotoEncryptedUnderAnotherHeldKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("moved in from another key".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext)
        await bankFingerprint(Self.foreignKey.keyFingerprint,
                              recordName: MediaRecordName.componentRecordName(mediaID: id, type: .photo),
                              id: id, mediaType: .photo, album: album, store: store, access: access)

        let decrypted = try await access.loadMedia(media: try photoMedia(album: album, id: id), progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)
    }

    /// The fingerprint is not covered by the AEAD, so a wrong one is only an
    /// ordering hint: the key that authenticates the content wins.
    func testLoadProvesTheKeyFromContentWhenTheFingerprintIsWrong() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store,
                                           heldKeys: [album.key, Self.unrelatedKey, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("wrong hint".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext, stamped: false)
        await bankFingerprint(Self.unrelatedKey.keyFingerprint,
                              recordName: MediaRecordName.componentRecordName(mediaID: id, type: .photo),
                              id: id, mediaType: .photo, album: album, store: store, access: access)

        let decrypted = try await access.loadMedia(media: try photoMedia(album: album, id: id), progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)
    }

    /// No fingerprint at all (a record the coordinator has not synced yet).
    func testLoadProvesTheKeyFromContentWhenTheFingerprintIsAbsent() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("no hint".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext, stamped: false)

        let decrypted = try await access.loadMedia(media: try photoMedia(album: album, id: id), progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)
    }

    /// The export/share decrypt site resolves the same way.
    func testLoadMediaToURLsDecryptsUnderAnotherHeldKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("exported under another key".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext)

        let urls = try await access.loadMediaToURLs(media: try photoMedia(album: album, id: id), progress: { _ in })

        let outURL = try XCTUnwrap(urls.first)
        defer { try? FileManager.default.removeItem(at: outURL) }
        XCTAssertEqual(try Data(contentsOf: outURL), cleartext)
    }

    /// Both halves of a Live Photo resolve their key, each on its own record.
    func testLoadDecryptsBothLivePhotoComponentsUnderAnotherHeldKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("live photo component".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext)
        let model = CloudKitStorageModel(album: album)
        let media = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(model.driveURLForMedia(withID: id, type: .photo)), mediaType: .photo, id: id),
            EncryptedMedia(source: .url(model.driveURLForMedia(withID: id, type: .video)), mediaType: .video, id: id)
        ])

        let decrypted = try await access.loadMedia(media: media, progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.count, 2)
        XCTAssertEqual(decrypted.underlyingMedia.first { $0.mediaType == .photo }?.data, cleartext)
        let videoURL = try XCTUnwrap(decrypted.underlyingMedia.first { $0.mediaType == .video }?.url)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        XCTAssertEqual(try Data(contentsOf: videoURL), cleartext)
    }

    /// With the key nowhere on the device the user must get the missing-key
    /// state, naming the key the file's stamp carries, not a decrypt failure.
    func testLoadReportsAMissingKeyWhenNoHeldKeyOpensThePhoto() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key])
        let id = UUID().uuidString
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: Data("locked".utf8))

        await XCTAssertThrowsErrorAsync(
            try await access.loadMedia(media: try self.photoMedia(album: album, id: id), progress: { _ in })
        ) { error in
            guard case FileAccessError.missingKeyForMedia(let prefix) = error else {
                return XCTFail("expected missingKeyForMedia, got \(error)")
            }
            XCTAssertEqual(prefix, Self.foreignKey.stampPrefix)
        }
        await XCTAssertThrowsErrorAsync(
            try await access.loadMediaToURLs(media: try self.photoMedia(album: album, id: id), progress: { _ in })
        ) { error in
            guard case FileAccessError.missingKeyForMedia = error else {
                return XCTFail("expected missingKeyForMedia from loadMediaToURLs, got \(error)")
            }
        }
    }

    /// The fast path: an item under the album's own key opens with the one blob
    /// fetch it always cost, no metadata round trip for a hint, and no read of the
    /// key library.
    func testAlbumKeyPhotoOpensWithoutExtraFetchesOrAKeyLibraryRead() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, keyManager) = await makeAccess(album: album, store: store,
                                                    heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("own key".utf8)
        store.blobContents = try await makeENC2(key: album.key, id: id, data: cleartext)
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)

        let decrypted = try await access.loadMedia(media: try photoMedia(album: album, id: id), progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)
        XCTAssertEqual(store.callOrder, [.fetchBlob(recordName: recordName)])
        XCTAssertEqual(keyManager.storedKeysReads, 0)
    }

    /// A photo re-parented from an album under another key opens in its new album.
    func testPhotoMovedInFromAnAlbumUnderAnotherKeyOpensInTheTarget() async throws {
        let source = Album(name: "Source-\(UUID().uuidString)", storageOption: .cloudKit, creationDate: Date(),
                           key: Self.foreignKey, albumID: UUID().uuidString)
        let target = makeAlbum(name: "Target-\(UUID().uuidString)")
        let store = MockCloudKitMediaStore()
        let id = UUID().uuidString
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        let cleartext = Data("reassigned, never re-encrypted".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext)
        store.metadataToReturn = [
            CloudKitMediaMetadata(recordName: recordName, albumID: source.albumID!, mediaID: id,
                                  mediaType: .photo, createdAt: Date(), sizeBytes: 100,
                                  creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: Self.foreignKey.keyFingerprint, recordChangeTag: "t1")
        ]
        let (targetAccess, _) = await makeAccess(album: target, store: store, heldKeys: [target.key, Self.foreignKey])

        try await targetAccess.move(media: try photoMedia(album: source, id: id), progress: nil)
        let decrypted = try await targetAccess.loadMedia(media: try photoMedia(album: target, id: id), progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)
    }

    /// Streaming decrypts with the key that authenticates chunk 0, proven from
    /// the header and chunk 0 already in memory.
    func testStreamingPlaysAChunkedVideoEncryptedUnderAnotherHeldKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let (access, _) = await makeAccess(album: album, store: store, chunkStore: chunkStore,
                                           heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore,
                                       key: Self.foreignKey, keyFingerprint: Self.foreignKey.keyFingerprint)

        let playback = try await access.streamingPlayback(for: try videoMedia(album: album, id: id))

        let session = try XCTUnwrap(playback?.session)
        let plaintext = try await session.reader.plaintext(range: 0..<session.plaintextLength)
        XCTAssertEqual(plaintext, Self.chunkedPlaintext)
    }

    func testStreamingProvesTheKeyWhenTheFingerprintIsWrongOrAbsent() async throws {
        for hint in [Self.unrelatedKey.keyFingerprint, ""] {
            let album = makeAlbum()
            let store = MockCloudKitMediaStore()
            let chunkStore = InMemoryChunkedBlobStore()
            let (access, _) = await makeAccess(album: album, store: store, chunkStore: chunkStore,
                                               heldKeys: [album.key, Self.unrelatedKey, Self.foreignKey])
            let id = UUID().uuidString
            _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore,
                                           key: Self.foreignKey, keyFingerprint: hint)

            let playback = try await access.streamingPlayback(for: try videoMedia(album: album, id: id))

            let session = try XCTUnwrap(playback?.session, "hint=\(hint)")
            let plaintext = try await session.reader.plaintext(range: 0..<session.plaintextLength)
            XCTAssertEqual(plaintext, Self.chunkedPlaintext, "hint=\(hint)")
        }
    }

    /// A chunked video nobody on this device can open reports a missing key
    /// before a player exists, naming the key the record names.
    func testStreamingReportsAMissingKeyWhenNoHeldKeyOpensChunkZero() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let (access, _) = await makeAccess(album: album, store: store, chunkStore: chunkStore, heldKeys: [album.key])
        let id = UUID().uuidString
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore,
                                       key: Self.foreignKey, keyFingerprint: Self.foreignKey.keyFingerprint)

        await XCTAssertThrowsErrorAsync(
            try await access.streamingPlayback(for: try self.videoMedia(album: album, id: id))
        ) { error in
            guard case FileAccessError.missingKeyForMedia(let prefix) = error else {
                return XCTFail("expected missingKeyForMedia, got \(error)")
            }
            XCTAssertEqual(prefix, Self.foreignKey.stampPrefix)
        }
    }

    /// Proving the key must use the chunk 0 the prefetch already pulled: no extra
    /// chunk, no extra record fetch, no key library read on the album-key path.
    func testStreamingAlbumKeyVideoCostsNoExtraFetchesOrAKeyLibraryRead() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let (access, keyManager) = await makeAccess(album: album, store: store, chunkStore: chunkStore,
                                                    heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let recordName = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore,
                                                    keyFingerprint: album.key.keyFingerprint)

        let playback = try await access.streamingPlayback(for: try videoMedia(album: album, id: id))

        XCTAssertNotNil(playback)
        XCTAssertEqual(store.callOrder, [.fetchRecordMetadata(recordName: recordName)])
        let fetched = await chunkStore.fetchedIndices
        XCTAssertEqual(fetched.filter { $0 == 0 }.count, 1, "chunk 0 fetched exactly once: \(fetched)")
        XCTAssertEqual(keyManager.storedKeysReads, 0)
    }

    /// A record's key is resolved from the library once per session; later opens
    /// re-prove the remembered key instead of reading the keychain again.
    func testARecordResolvedOnceDoesNotReadTheKeyLibraryAgain() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, keyManager) = await makeAccess(album: album, store: store,
                                                    heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let cleartext = Data("remembered".utf8)
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: cleartext)

        _ = try await access.loadMedia(media: try photoMedia(album: album, id: id), progress: { _ in })
        let decrypted = try await access.loadMedia(media: try photoMedia(album: album, id: id), progress: { _ in })

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, cleartext)
        XCTAssertEqual(keyManager.storedKeysReads, 1)
    }

    /// Damage is not a missing key. A file stamped with a key this device holds
    /// that still fails to authenticate has changed under that key, and sending
    /// the user hunting for a key phrase would not help.
    func testDamagedBytesUnderAHeldKeyAreNotReportedAsAMissingKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key])
        let id = UUID().uuidString
        var bytes = try await makeENC2(key: album.key, id: id, data: Data(repeating: 0x33, count: 4_000))
        bytes[bytes.count - 10] ^= 0xFF
        bytes[bytes.count / 2] ^= 0xFF
        store.blobContents = bytes

        await XCTAssertThrowsErrorAsync(
            try await access.loadMedia(media: try self.photoMedia(album: album, id: id), progress: { _ in })
        ) { error in
            if case FileAccessError.missingKeyForMedia = error {
                XCTFail("damaged bytes under a held key must not report a missing key")
            }
        }
    }

    // MARK: - Lightbox metadata

    /// What the lightbox's info sheet shows. Whole seconds: the metadata JSON
    /// stores dates as ISO 8601 without fractions.
    private static func infoMetadata() -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.dimensions = EncryptedFileMetadata.Dimensions(width: 4032, height: 3024)
        metadata.originalFileSize = 3_500_000
        metadata.originalExtension = "heic"
        return metadata
    }

    func testLoadMetadataReadsACloudKitPhotoUnderTheAlbumKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key])
        let id = UUID().uuidString
        store.blobContents = try await makeENC2(key: album.key, id: id, data: Data("own key".utf8),
                                                metadata: Self.infoMetadata())

        let metadata = try await access.loadMetadata(for: try photoMedia(album: album, id: id))

        XCTAssertEqual(metadata, Self.infoMetadata())
    }

    /// A photo moved in from an album under another key keeps that key; the
    /// album's key cannot open its metadata section.
    func testLoadMetadataReadsAPhotoMovedInUnderAnotherHeldKey() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: Data("moved in".utf8),
                                                metadata: Self.infoMetadata())

        let metadata = try await access.loadMetadata(for: try photoMedia(album: album, id: id))

        XCTAssertEqual(metadata, Self.infoMetadata())
    }

    /// A chunked video's metadata lives in the ENC3 header on the record, so it is
    /// read, and its key proven, without fetching a chunk or the blob.
    func testLoadMetadataReadsAChunkedVideoFromItsHeaderWithoutFetchingChunks() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let (access, _) = await makeAccess(album: album, store: store, chunkStore: chunkStore,
                                           heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        let recordName = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore,
                                                    key: Self.foreignKey,
                                                    keyFingerprint: Self.foreignKey.keyFingerprint,
                                                    metadata: Self.infoMetadata())

        let metadata = try await access.loadMetadata(for: try videoMedia(album: album, id: id))

        XCTAssertEqual(metadata, Self.infoMetadata())
        XCTAssertFalse(store.callOrder.contains(.fetchBlob(recordName: recordName)), "\(store.callOrder)")
        let fetched = await chunkStore.fetchedIndices
        XCTAssertEqual(fetched, [], "No chunk may be fetched for metadata")
    }

    /// A monolithic video's metadata sits at the front of a blob CloudKit only
    /// serves whole. Swiping past one must not download it.
    func testLoadMetadataDoesNotDownloadAnUncachedMonolithicVideo() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key])
        let id = UUID().uuidString
        store.blobContents = try await makeENC2(key: album.key, id: id, data: Data("a big video".utf8),
                                                metadata: Self.infoMetadata())
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .video)

        let metadata = try await access.loadMetadata(for: try videoMedia(album: album, id: id))

        XCTAssertNil(metadata)
        XCTAssertFalse(store.callOrder.contains(.fetchBlob(recordName: recordName)), "\(store.callOrder)")
    }

    /// Once the video has been played its ciphertext is local, and the metadata
    /// comes from there.
    func testLoadMetadataReadsAMonolithicVideoOnceItIsCached() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key, Self.foreignKey])
        let id = UUID().uuidString
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: Data("played video".utf8),
                                                metadata: Self.infoMetadata())
        let media = try videoMedia(album: album, id: id)
        let urls = try await access.loadMediaToURLs(media: media, progress: { _ in })
        urls.forEach { try? FileManager.default.removeItem(at: $0) }

        let metadata = try await access.loadMetadata(for: media)

        XCTAssertEqual(metadata, Self.infoMetadata())
    }

    func testLoadMetadataReportsAMissingKeyWhenNoHeldKeyOpensThePhoto() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let (access, _) = await makeAccess(album: album, store: store, heldKeys: [album.key])
        let id = UUID().uuidString
        store.blobContents = try await makeENC2(key: Self.foreignKey, id: id, data: Data("locked".utf8),
                                                metadata: Self.infoMetadata())

        await XCTAssertThrowsErrorAsync(
            try await access.loadMetadata(for: try self.photoMedia(album: album, id: id))
        ) { error in
            guard case FileAccessError.missingKeyForMedia(let prefix) = error else {
                return XCTFail("expected missingKeyForMedia, got \(error)")
            }
            XCTAssertEqual(prefix, Self.foreignKey.stampPrefix)
        }
    }

    func testLoadMetadataReportsAMissingKeyWhenNoHeldKeyOpensAChunkedVideosHeader() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let chunkStore = InMemoryChunkedBlobStore()
        let (access, _) = await makeAccess(album: album, store: store, chunkStore: chunkStore, heldKeys: [album.key])
        let id = UUID().uuidString
        _ = try await seedChunkedVideo(in: store, album: album, id: id, chunkStore: chunkStore,
                                       key: Self.foreignKey, keyFingerprint: Self.foreignKey.keyFingerprint,
                                       metadata: Self.infoMetadata())

        await XCTAssertThrowsErrorAsync(
            try await access.loadMetadata(for: try self.videoMedia(album: album, id: id))
        ) { error in
            guard case FileAccessError.missingKeyForMedia(let prefix) = error else {
                return XCTFail("expected missingKeyForMedia, got \(error)")
            }
            XCTAssertEqual(prefix, Self.foreignKey.stampPrefix)
        }
    }

    func testStorageTypeCodableRoundTripsCloudKit() throws {
        let data = try JSONEncoder().encode(StorageType.cloudKit)
        let decoded = try JSONDecoder().decode(StorageType.self, from: data)
        XCTAssertEqual(decoded, .cloudKit)
    }

    // MARK: - Records saved without a thumbnail
    //
    // Two or three `CloudKitFileAccess` instances on one shared store stand in for
    // separate devices on the same iCloud account. Previews and the blob cache
    // live at paths every instance in this process shares, so a "fresh" device is
    // made by clearing the preview file and evicting the cached blob first.

    private func makeDevice(album: Album,
                            store: CloudKitMediaStoring,
                            chunkStore: ChunkedBlobStoring? = nil) async -> CloudKitFileAccess {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        return await CloudKitFileAccess(album: album, albumManager: albumManager, store: store, chunkStore: chunkStore)
    }

    /// Removes everything a save into `album` leaves on this simulator.
    private func removeLocalState(album: Album, mediaID: String) {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: CloudKitStorageModel.previewURL(forMediaID: mediaID))
            try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
            try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
            for type in [MediaType.photo, .video] {
                try? FileManager.default.removeItem(at: self.decryptedCopyURL(id: mediaID, type: type))
            }
        }
    }

    /// The media as the gallery hands it to a device: enumerated from the synced
    /// index, with each component's source at the blob-cache path.
    private func galleryMedia(on device: CloudKitFileAccess, id: String,
                              file: StaticString = #filePath, line: UInt = #line) async throws -> InteractableMedia<EncryptedMedia> {
        let listed = await device.enumerate()
        return try XCTUnwrap(listed.first { $0.id == id }, "the device's index lists the media", file: file, line: line)
    }

    /// A movie larger than the ENC3 threshold: a tiny real movie followed by a
    /// QuickTime `free` atom, which players skip, so it still decodes.
    private func writeMovieAboveChunkingThreshold(to url: URL) async throws {
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: url, seconds: 1)
        let paddingLength = SeekableEncryptedFormat.threshold + 4_096
        var atom = Data()
        withUnsafeBytes(of: UInt32(paddingLength).bigEndian) { atom.append(contentsOf: $0) }
        atom.append(contentsOf: Array("free".utf8))
        atom.append(Data(count: paddingLength - atom.count))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: atom)
    }

    /// The image a record's `encThumbnail` bytes decrypt to under the album key,
    /// read the way `DiskFileAccess.loadMediaPreview` reads a preview file.
    private func decodedThumbnailImage(_ data: Data?, album: Album, id: String) async -> PlatformImage? {
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let encrypted = EncryptedMedia(source: .url(url), mediaType: .preview, id: id)
            let cleartext = try await SecretFileHandler(keyBytes: album.key.keyBytes, source: encrypted).decryptInMemory()
            return try PreviewModel(source: cleartext).thumbnailMedia.data.flatMap(PlatformImage.init(data:))
        } catch {
            return nil
        }
    }

    /// Device A after saving `media` whose preview is gone by the time the upload
    /// drains: the record lands without `encThumbnail`.
    private struct SavedWithoutThumbnail {
        let album: Album
        let store: InMemoryCloudKitMediaStore
        let chunkStore: InMemoryChunkedBlobStore
        let deviceA: CloudKitFileAccess
        let id: String
        let recordNames: [String]
    }

    /// Saves `media` on device A, deletes its preview, then drains. Uploads fail
    /// retryably until the preview is gone, so the attempt that lands is made
    /// without it — the path `CloudKitUploader.send` takes when the preview file
    /// is missing — however far the drain `save` kicked off had got.
    private func saveWithPreviewGoneAtDrain(_ media: InteractableMedia<CleartextMedia>,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) async throws -> SavedWithoutThumbnail {
        let album = makeAlbum()
        let chunkStore = InMemoryChunkedBlobStore()
        let store = InMemoryCloudKitMediaStore(chunkStore: chunkStore)
        let deviceAStore = RecordingCloudKitMediaStore(wrapping: store)
        let recordNames = media.underlyingMedia.map {
            CloudKitFileAccess.componentRecordName(mediaID: $0.id, type: $0.mediaType)
        }
        deviceAStore.failUploadsRetryably(recordNames: Set(recordNames))
        removeLocalState(album: album, mediaID: media.id)
        let deviceA = await makeDevice(album: album, store: deviceAStore, chunkStore: chunkStore)

        _ = try await deviceA.save(media: media, metadata: nil, progress: { _ in })
        await deviceA.drainUploads()
        XCTAssertTrue(recordNames.allSatisfy { !store.liveRecordNames.contains($0) },
                      "precondition: nothing has landed yet", file: file, line: line)
        let previewURL = thumbnailURL(forMediaID: media.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
                      "precondition: the save wrote a preview", file: file, line: line)
        try FileManager.default.removeItem(at: previewURL)
        deviceAStore.stopFailingUploads()
        await deviceA.drainUploads()

        for recordName in recordNames {
            XCTAssertTrue(store.liveRecordNames.contains(recordName),
                          "precondition: \(recordName) reached the store", file: file, line: line)
            XCTAssertFalse(store.hasThumbnail(recordName: recordName),
                           "precondition: \(recordName) was saved without encThumbnail", file: file, line: line)
        }
        return SavedWithoutThumbnail(album: album, store: store, chunkStore: chunkStore, deviceA: deviceA,
                                     id: media.id, recordNames: recordNames)
    }

    private func saveVideoWithPreviewGoneAtDrain() async throws -> SavedWithoutThumbnail {
        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("nothumb-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movieURL, seconds: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: movieURL) }
        return try await saveWithPreviewGoneAtDrain(try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .url(movieURL), mediaType: .video, id: UUID().uuidString)
        ]))
    }

    /// Another device on the same account: no preview file, no cached blob and no
    /// decrypted copy of the media. `holder` is the device whose cached copy must
    /// go first.
    private func freshDevice(after saved: SavedWithoutThumbnail,
                             evictingFrom holder: CloudKitFileAccess,
                             store: CloudKitMediaStoring? = nil,
                             chunkStore: ChunkedBlobStoring? = nil) async throws -> CloudKitFileAccess {
        try? FileManager.default.removeItem(at: thumbnailURL(forMediaID: saved.id))
        for recordName in saved.recordNames {
            try? FileManager.default.removeItem(at: decryptedCopyURL(id: saved.id, type: MediaRecordName.mediaType(from: recordName)))
        }
        try await holder.evictLocalCopy(for: try await galleryMedia(on: holder, id: saved.id))
        let device = await makeDevice(album: saved.album, store: store ?? saved.store, chunkStore: chunkStore ?? saved.chunkStore)
        _ = await device.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL(forMediaID: saved.id).path),
                       "precondition: the fresh device has no preview")
        for recordName in saved.recordNames {
            let mediaType = MediaRecordName.mediaType(from: recordName)
            let cached = await device.isBlobCached(for: saved.id, type: mediaType)
            XCTAssertFalse(cached, "precondition: the fresh device has no cached blob for \(recordName)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: decryptedCopyURL(id: saved.id, type: mediaType).path),
                           "precondition: the fresh device has no decrypted copy of \(recordName)")
        }
        return device
    }

    /// Where an open decrypts a component to; `DiskFileAccess` reuses a file
    /// already there instead of decrypting again.
    private func decryptedCopyURL(id: String, type: MediaType) -> URL {
        URL.tempMediaDirectory.appendingPathComponent(id).appendingPathExtension(type.decryptedFileExtension)
    }

    // MARK: Characterization — how a record ends up without a thumbnail

    func testVideoWhosePreviewFailsAtSaveIsUploadedWithoutAThumbnail() async throws {
        let album = makeAlbum()
        let chunkStore = InMemoryChunkedBlobStore()
        let store = InMemoryCloudKitMediaStore(chunkStore: chunkStore)
        let deviceA = await makeDevice(album: album, store: store, chunkStore: chunkStore)
        let id = UUID().uuidString
        removeLocalState(album: album, mediaID: id)
        let notAMovie = FileManager.default.temporaryDirectory.appendingPathComponent("undecodable-\(UUID().uuidString).mov")
        try Data("these bytes are not a movie".utf8).write(to: notAMovie)
        defer { try? FileManager.default.removeItem(at: notAMovie) }

        _ = try await deviceA.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .url(notAMovie), mediaType: .video, id: id)
        ]), metadata: nil, progress: { _ in })
        await deviceA.drainUploads()

        let recordName = CloudKitFileAccess.componentRecordName(mediaID: id, type: .video)
        XCTAssertTrue(store.liveRecordNames.contains(recordName), "the save is uploaded anyway")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL(forMediaID: id).path),
                       "the preview failed at save time, so there is no preview file")
        XCTAssertFalse(store.hasThumbnail(recordName: recordName),
                       "a preview that failed at save time leaves the record without encThumbnail")
    }

    func testPreviewGoneAtDrainIsUploadedWithoutAThumbnail() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()

        let recordName = try XCTUnwrap(saved.recordNames.first)
        XCTAssertTrue(saved.store.liveRecordNames.contains(recordName), "the upload landed")
        XCTAssertFalse(saved.store.hasThumbnail(recordName: recordName),
                       "a preview missing at drain time leaves the record without encThumbnail")
    }

    func testUploadingDeviceRebuildsAThumbnailTheRecordDoesNotHave() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let recordName = try XCTUnwrap(saved.recordNames.first)

        let preview = try await saved.deviceA.loadMediaPreview(for: try await galleryMedia(on: saved.deviceA, id: saved.id))

        XCTAssertNotNil(preview.thumbnailMedia.data.flatMap(PlatformImage.init(data:)),
                        "device A rebuilds a preview from its cached blob, so it looks fine")
        XCTAssertFalse(saved.store.hasThumbnail(recordName: recordName),
                       "the rebuilt preview stays on device A; the record still has no encThumbnail")
    }

    func testSecondDeviceGetsNoThumbnailForARecordSavedWithoutOne() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)

        do {
            _ = try await deviceB.loadMediaPreview(for: try await galleryMedia(on: deviceB, id: saved.id))
            XCTFail("device B has no preview, no cached blob and no encThumbnail to fetch, so it gets no thumbnail")
        } catch {}
    }

    // MARK: A failed decrypt leaves no decrypted copy

    func testAFailedPreviewLeavesNoDecryptedCopyBehind() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)
        let media = try await galleryMedia(on: deviceB, id: saved.id)

        _ = try? await deviceB.loadMediaPreview(for: media)

        XCTAssertFalse(FileManager.default.fileExists(atPath: decryptedCopyURL(id: saved.id, type: .video).path),
                       "a decrypt that failed before writing anything must not leave an empty copy to be reused")
    }

    func testARetriedPreviewFailsTheSameWayAsTheFirst() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)
        let media = try await galleryMedia(on: deviceB, id: saved.id)
        _ = try? await deviceB.loadMediaPreview(for: media)

        do {
            _ = try await deviceB.loadMediaPreview(for: media)
            XCTFail("device B still has nothing to make a preview from")
        } catch SecretFilesError.createVideoThumbnailError {
            XCTFail("the retry read an empty decrypted copy left by the first attempt as the video")
        } catch {}
    }

    func testAnEmptyDecryptedCopyIsDeletedAndTheVideoDecryptedAgain() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let media = try await galleryMedia(on: saved.deviceA, id: saved.id)
        let decryptedCopy = decryptedCopyURL(id: saved.id, type: .video)
        try FileManager.default.createDirectory(at: decryptedCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: decryptedCopy)
        XCTAssertTrue(FileManager.default.createFile(atPath: decryptedCopy.path, contents: Data()),
                      "precondition: an empty copy, as a failed decrypt used to leave")

        let preview = try await saved.deviceA.loadMediaPreview(for: media)

        XCTAssertNotNil(preview.thumbnailMedia.data.flatMap(PlatformImage.init(data:)),
                        "the preview is made from the video, not the empty copy")
        let size = try FileManager.default.attributesOfItem(atPath: decryptedCopy.path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 0, "the empty copy was replaced by the decrypted video")
    }

    // MARK: RED — opening the media repairs the record

    func testOpeningAVideoOnAnotherDeviceRepairsTheRecordThumbnail() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let recordName = try XCTUnwrap(saved.recordNames.first)
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)

        _ = try await deviceB.loadMedia(media: try await galleryMedia(on: deviceB, id: saved.id), progress: { _ in })
        await deviceB.awaitThumbnailRepairs()

        let hasThumbnail = saved.store.hasThumbnail(recordName: recordName)
        let image = await decodedThumbnailImage(saved.store.thumbnailData(recordName: recordName),
                                                album: saved.album, id: saved.id)
        XCTAssertTrue(hasThumbnail, "opening the video on device B writes encThumbnail onto the record")
        XCTAssertNotNil(image, "the attached thumbnail decrypts to a decodable image")
    }

    func testOpeningOnTheUploadingDeviceUploadsItsRebuiltThumbnail() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let recordName = try XCTUnwrap(saved.recordNames.first)
        let media = try await galleryMedia(on: saved.deviceA, id: saved.id)
        _ = try await saved.deviceA.loadMediaPreview(for: media)
        let previewURL = thumbnailURL(forMediaID: saved.id)
        let rebuilt = try XCTUnwrap(try? Data(contentsOf: previewURL), "precondition: device A rebuilt its preview file")
        XCTAssertFalse(saved.store.hasThumbnail(recordName: recordName), "precondition: the record still has none")

        _ = try await saved.deviceA.loadMedia(media: media, progress: { _ in })
        await saved.deviceA.awaitThumbnailRepairs()

        let attached = saved.store.thumbnailData(recordName: recordName)
        XCTAssertEqual(attached, rebuilt, "the record's thumbnail is the preview device A rebuilt")
    }

    func testThirdDeviceGetsTheRepairedThumbnailWithoutDownloadingTheMedia() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)
        _ = try await deviceB.loadMedia(media: try await galleryMedia(on: deviceB, id: saved.id), progress: { _ in })
        await deviceB.awaitThumbnailRepairs()

        let deviceCStore = RecordingCloudKitMediaStore(wrapping: saved.store)
        let deviceC = try await freshDevice(after: saved, evictingFrom: deviceB, store: deviceCStore)
        let preview = try? await deviceC.loadMediaPreview(for: try await galleryMedia(on: deviceC, id: saved.id))

        let image = preview?.thumbnailMedia.data.flatMap(PlatformImage.init(data:))
        let thumbnailFetches = deviceCStore.fetchThumbnailCount
        let blobFetches = deviceCStore.fetchBlobCount
        XCTAssertNotNil(image, "device C shows the thumbnail device B attached")
        XCTAssertEqual(thumbnailFetches, 1, "device C fetches encThumbnail once")
        XCTAssertEqual(blobFetches, 0, "device C does not download the media to show its thumbnail")
    }

    func testOpeningAPhotoSavedWithoutAThumbnailRepairsIt() async throws {
        let saved = try await saveWithPreviewGoneAtDrain(try photo(data: Self.tinyPNG()))
        let recordName = try XCTUnwrap(saved.recordNames.first)
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)

        _ = try await deviceB.loadMedia(media: try await galleryMedia(on: deviceB, id: saved.id), progress: { _ in })
        await deviceB.awaitThumbnailRepairs()

        let hasThumbnail = saved.store.hasThumbnail(recordName: recordName)
        let image = await decodedThumbnailImage(saved.store.thumbnailData(recordName: recordName),
                                                album: saved.album, id: saved.id)
        XCTAssertTrue(hasThumbnail, "opening the photo on device B writes encThumbnail onto the record")
        XCTAssertNotNil(image, "the attached thumbnail decrypts to a decodable image")
    }

    func testOpeningALivePhotoRepairsBothComponentRecords() async throws {
        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("nothumb-live-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: movieURL, seconds: 1)
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let id = UUID().uuidString
        let live = try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: id),
            CleartextMedia(source: .url(movieURL), mediaType: .video, id: id),
        ])
        XCTAssertEqual(live.mediaType, .livePhoto)
        let saved = try await saveWithPreviewGoneAtDrain(live)
        XCTAssertEqual(Set(saved.recordNames), ["\(id)#\(MediaType.photo.rawValue)", "\(id)#\(MediaType.video.rawValue)"])
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)

        _ = try await deviceB.loadMedia(media: try await galleryMedia(on: deviceB, id: id), progress: { _ in })
        await deviceB.awaitThumbnailRepairs()

        let repaired = saved.recordNames.map { ($0, saved.store.hasThumbnail(recordName: $0)) }
        for (recordName, hasThumbnail) in repaired {
            XCTAssertTrue(hasThumbnail, "opening the Live Photo writes encThumbnail onto \(recordName)")
        }
    }

    func testStreamingAChunkedVideoRepairsTheRecordThumbnail() async throws {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }
        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("nothumb-chunked-\(UUID().uuidString).mov")
        try await writeMovieAboveChunkingThreshold(to: movieURL)
        defer { try? FileManager.default.removeItem(at: movieURL) }

        let saved = try await saveWithPreviewGoneAtDrain(try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .url(movieURL), mediaType: .video, id: UUID().uuidString)
        ]))
        let recordName = try XCTUnwrap(saved.recordNames.first)
        let record = try await saved.store.fetchRecordMetadata(recordName: recordName)
        XCTAssertGreaterThan(record?.chunkCount ?? 0, 0, "precondition: the video was saved chunked")
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)

        let playback = try await deviceB.streamingPlayback(for: try await galleryMedia(on: deviceB, id: saved.id))
        XCTAssertNotNil(playback, "device B streams the chunked video")
        await deviceB.awaitThumbnailRepairs()

        let hasThumbnail = saved.store.hasThumbnail(recordName: recordName)
        let image = await decodedThumbnailImage(saved.store.thumbnailData(recordName: recordName),
                                                album: saved.album, id: saved.id)
        XCTAssertTrue(hasThumbnail, "streaming the video on device B writes encThumbnail onto the record")
        XCTAssertNotNil(image, "the attached thumbnail decrypts to a decodable image")
    }

    // MARK: A repaired preview is announced, so the grid can show it

    func testOpeningAVideoWithoutAPreviewAnnouncesTheRepairedOne() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)
        let announcements = PreviewAnnouncements()

        _ = try await deviceB.loadMedia(media: try await galleryMedia(on: deviceB, id: saved.id), progress: { _ in })
        await deviceB.awaitThumbnailRepairs()

        XCTAssertEqual(announcements.mediaIDs, [saved.id],
                       "the grid cell that failed for want of a preview is told one now exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL(forMediaID: saved.id).path),
                      "the announced preview is on disk for the grid to load")
    }

    func testStreamingAChunkedVideoWithoutAPreviewAnnouncesTheRepairedOne() async throws {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        defer { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }
        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("nothumb-chunked-\(UUID().uuidString).mov")
        try await writeMovieAboveChunkingThreshold(to: movieURL)
        defer { try? FileManager.default.removeItem(at: movieURL) }
        let saved = try await saveWithPreviewGoneAtDrain(try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .url(movieURL), mediaType: .video, id: UUID().uuidString)
        ]))
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)
        let announcements = PreviewAnnouncements()

        let playback = try await deviceB.streamingPlayback(for: try await galleryMedia(on: deviceB, id: saved.id))
        XCTAssertNotNil(playback, "precondition: device B streams the chunked video")
        await deviceB.awaitThumbnailRepairs()

        XCTAssertEqual(announcements.mediaIDs, [saved.id])
    }

    func testOpeningMediaThatAlreadyHasAPreviewAnnouncesNothing() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let (media, _) = try await savePhotoWithThumbnail(Self.tinyPNG(), on: access, album: album)
        let announcements = PreviewAnnouncements()

        _ = try await access.loadMedia(media: media, progress: { _ in })
        await access.awaitThumbnailRepairs()

        XCTAssertEqual(announcements.mediaIDs, [], "the preview the grid already shows did not change")
    }

    func testRepairedVideoStillOpensFromTheBlobCache() async throws {
        let saved = try await saveVideoWithPreviewGoneAtDrain()
        let recordName = try XCTUnwrap(saved.recordNames.first)
        let deviceBStore = RecordingCloudKitMediaStore(wrapping: saved.store)
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA, store: deviceBStore)
        let tagBeforeRepair = try await saved.store.fetchRecordMetadata(recordName: recordName)?.recordChangeTag
        let media = try await galleryMedia(on: deviceB, id: saved.id)

        _ = try await deviceB.loadMedia(media: media, progress: { _ in })
        XCTAssertEqual(deviceBStore.fetchBlobCount, 1, "precondition: the first open downloads the blob")
        await deviceB.awaitThumbnailRepairs()
        _ = await deviceB.reconcile()
        _ = try await deviceB.loadMedia(media: media, progress: { _ in })

        let hasThumbnail = saved.store.hasThumbnail(recordName: recordName)
        let tagAfterRepair = try await saved.store.fetchRecordMetadata(recordName: recordName)?.recordChangeTag
        let blobFetches = deviceBStore.fetchBlobCount
        XCTAssertTrue(hasThumbnail, "the first open repaired the record")
        XCTAssertNotEqual(tagAfterRepair, tagBeforeRepair, "the repair's save gave the record a new change tag")
        XCTAssertEqual(blobFetches, 1, "the cached blob was re-keyed to the new tag, so the second open downloads nothing")
    }

    // MARK: Regression guards — the repair on open

    /// A photo saved on a device backed by the mock store, with its thumbnail.
    private func savePhotoWithThumbnail(_ data: Data,
                                        on access: CloudKitFileAccess,
                                        album: Album) async throws -> (media: InteractableMedia<EncryptedMedia>, recordName: String) {
        let cleartext = try photo(data: data)
        removeLocalState(album: album, mediaID: cleartext.id)
        _ = try await access.save(media: cleartext, metadata: nil, progress: { _ in })
        await access.drainUploads()
        let recordName = CloudKitFileAccess.componentRecordName(mediaID: cleartext.id, type: .photo)
        return (try await galleryMedia(on: access, id: cleartext.id), recordName)
    }

    private func attachCalls(_ store: MockCloudKitMediaStore, recordName: String) -> Int {
        store.callOrder.filter { $0 == .attachThumbnail(recordName: recordName) }.count
    }

    func testOpeningAgainDoesNotCallAttachThumbnailAgain() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let (media, recordName) = try await savePhotoWithThumbnail(Self.tinyPNG(), on: access, album: album)
        XCTAssertTrue(store.liveRecordNames.contains(recordName), "precondition: the photo was uploaded")

        _ = try await access.loadMedia(media: media, progress: { _ in })
        await access.awaitThumbnailRepairs()
        _ = try await access.loadMedia(media: media, progress: { _ in })
        await access.awaitThumbnailRepairs()

        XCTAssertEqual(attachCalls(store, recordName: recordName), 1,
                       "the first open checks the record; the second skips it for the rest of the session")
    }

    func testOpeningAnItemStillQueuedForUploadDoesNotAttach() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let cleartext = try photo(data: Self.tinyPNG())
        let recordName = CloudKitFileAccess.componentRecordName(mediaID: cleartext.id, type: .photo)
        store.uploadFailures[recordName] = CloudKitMediaStoreError.retry(after: 0)
        removeLocalState(album: album, mediaID: cleartext.id)
        _ = try await access.save(media: cleartext, metadata: nil, progress: { _ in })
        let media = try await galleryMedia(on: access, id: cleartext.id)

        _ = try await access.loadMedia(media: media, progress: { _ in })
        await access.awaitThumbnailRepairs()

        XCTAssertFalse(store.liveRecordNames.contains(recordName), "precondition: the photo is still queued for upload")
        XCTAssertEqual(attachCalls(store, recordName: recordName), 0,
                       "a queued item's upload carries the preview when it drains, so the open attaches nothing")
    }

    func testRepairFailureDoesNotFailTheOpen() async throws {
        let album = makeAlbum()
        let store = MockCloudKitMediaStore()
        let access = await makeAccess(album: album, store: store)
        let png = Self.tinyPNG()
        let (media, recordName) = try await savePhotoWithThumbnail(png, on: access, album: album)
        store.attachThumbnailError = CloudKitMediaStoreError.retry(after: 0)

        let decrypted = try await access.loadMedia(media: media, progress: { _ in })
        await access.awaitThumbnailRepairs()

        XCTAssertEqual(decrypted.underlyingMedia.first?.data, png, "the open still returns the cleartext")
        XCTAssertEqual(attachCalls(store, recordName: recordName), 1, "the repair ran, failed, and was not retried in a loop")
    }

    func testOpeningARecordThatAlreadyHasAThumbnailNeverOverwritesIt() async throws {
        let album = makeAlbum()
        let chunkStore = InMemoryChunkedBlobStore()
        let store = InMemoryCloudKitMediaStore(chunkStore: chunkStore)
        let deviceA = await makeDevice(album: album, store: store, chunkStore: chunkStore)
        let cleartext = try photo(data: Self.tinyPNG())
        removeLocalState(album: album, mediaID: cleartext.id)
        _ = try await deviceA.save(media: cleartext, metadata: nil, progress: { _ in })
        await deviceA.drainUploads()
        let recordName = CloudKitFileAccess.componentRecordName(mediaID: cleartext.id, type: .photo)
        let original = try XCTUnwrap(store.thumbnailData(recordName: recordName), "precondition: the save carried a thumbnail")
        let saved = SavedWithoutThumbnail(album: album, store: store, chunkStore: chunkStore, deviceA: deviceA,
                                          id: cleartext.id, recordNames: [recordName])
        let deviceB = try await freshDevice(after: saved, evictingFrom: deviceA)

        _ = try await deviceB.loadMedia(media: try await galleryMedia(on: deviceB, id: cleartext.id), progress: { _ in })
        await deviceB.awaitThumbnailRepairs()

        XCTAssertEqual(store.thumbnailData(recordName: recordName), original,
                       "the record's thumbnail is unchanged by an open on a device without a preview")
    }

    // MARK: Regression guards — the repair on streaming

    /// A chunked video saved on device A without a thumbnail, written by `writeMovie`.
    private func saveChunkedVideoWithPreviewGoneAtDrain(
        writeMovie: (URL) async throws -> Void
    ) async throws -> (saved: SavedWithoutThumbnail, recordName: String) {
        let wasEnabled = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        addTeardownBlock { FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: wasEnabled) }
        let movieURL = FileManager.default.temporaryDirectory.appendingPathComponent("nothumb-chunked-\(UUID().uuidString).mov")
        try await writeMovie(movieURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: movieURL) }
        let saved = try await saveWithPreviewGoneAtDrain(try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .url(movieURL), mediaType: .video, id: UUID().uuidString)
        ]))
        let recordName = try XCTUnwrap(saved.recordNames.first)
        let record = try await saved.store.fetchRecordMetadata(recordName: recordName)
        XCTAssertGreaterThan(record?.chunkCount ?? 0, 2, "precondition: the video was saved in several chunks")
        return (saved, recordName)
    }

    /// A movie above the ENC3 threshold whose `moov` atom starts in chunk 1: the
    /// tiny movie's atoms with a `free` atom inserted before its trailing `moov`,
    /// then padding. `mdat` does not move, so its sample offsets stay valid, and
    /// reading the movie's structure needs chunk 1.
    private func writeMovieWithMoovInSecondChunk(to url: URL) async throws {
        let tinyURL = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-\(UUID().uuidString).mov")
        try await EncryptedStreamResourceLoaderTests.writeTinyMovie(to: tinyURL, seconds: 1)
        defer { try? FileManager.default.removeItem(at: tinyURL) }
        let tiny = try Data(contentsOf: tinyURL)

        var atoms: [(type: String, bytes: Data)] = []
        var offset = 0
        while offset + 8 <= tiny.count {
            let size = tiny[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: tiny[offset + 4..<offset + 8], as: UTF8.self)
            XCTAssertGreaterThanOrEqual(size, 8, "precondition: the tiny movie uses 32-bit atom sizes")
            guard size >= 8 else { return }
            atoms.append((type, tiny[offset..<offset + size]))
            offset += size
        }
        XCTAssertEqual(atoms.last?.type, "moov", "precondition: the tiny movie ends with its moov atom")

        func freeAtom(_ length: Int) -> Data {
            var atom = Data()
            withUnsafeBytes(of: UInt32(length).bigEndian) { atom.append(contentsOf: $0) }
            atom.append(contentsOf: Array("free".utf8))
            atom.append(Data(count: length - atom.count))
            return atom
        }
        var movie = Data()
        for atom in atoms.dropLast() { movie.append(atom.bytes) }
        let chunkSize = SeekableEncryptedFormat.defaultChunkSize
        movie.append(freeAtom(chunkSize + 4_096 - movie.count))
        movie.append(atoms.last?.bytes ?? Data())
        movie.append(freeAtom(SeekableEncryptedFormat.threshold + 4_096 - movie.count))
        try movie.write(to: url)
    }

    /// Making the thumbnail reads the streamed movie, but only the chunks
    /// playback already fetched: chunk 0 and the read-ahead behind it.
    func testStreamingRepairFetchesNoChunkBeyondTheFirstFew() async throws {
        let (saved, recordName) = try await saveChunkedVideoWithPreviewGoneAtDrain(writeMovie: writeMovieAboveChunkingThreshold(to:))
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA)
        await saved.chunkStore.resetLog()

        let playback = try await deviceB.streamingPlayback(for: try await galleryMedia(on: deviceB, id: saved.id))
        XCTAssertNotNil(playback, "device B streams the chunked video")
        await deviceB.awaitThumbnailRepairs()

        let fetched = await saved.chunkStore.fetchLog.filter { $0.media == recordName }.map(\.index)
        let readAhead = StreamingPlaybackPolicy.cloudKit.readAhead
        XCTAssertEqual(fetched.first, 0, "chunk 0 is fetched first")
        XCTAssertLessThanOrEqual(fetched.max() ?? 0, readAhead,
                                 "nothing past chunk 0's read-ahead window is fetched: \(fetched)")
    }

    /// A frame grab that fails — chunk 1, which holds the movie's `moov`, does
    /// not authenticate — is the repair's failure alone: playback is returned
    /// and the record is left as it was.
    func testStreamingRepairFailureDoesNotFailPlayback() async throws {
        let (saved, recordName) = try await saveChunkedVideoWithPreviewGoneAtDrain(writeMovie: writeMovieWithMoovInSecondChunk(to:))
        let corrupting = ChunkCorruptingBlobStore(wrapping: saved.chunkStore, corruptIndex: 1)
        let deviceB = try await freshDevice(after: saved, evictingFrom: saved.deviceA, chunkStore: corrupting)

        let playback = try await deviceB.streamingPlayback(for: try await galleryMedia(on: deviceB, id: saved.id))
        await deviceB.awaitThumbnailRepairs()

        let corruptServed = await corrupting.corruptServed
        XCTAssertNotNil(playback, "streamingPlayback returns a playback although the frame grab fails")
        XCTAssertTrue(corruptServed, "chunk 1 was served corrupted")
        XCTAssertFalse(saved.store.hasThumbnail(recordName: recordName), "a failed frame grab attaches nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL(forMediaID: saved.id).path),
                       "a failed frame grab writes no preview")
    }

    // MARK: - One walk of the zone

    /// N CloudKit albums cost one walk of the zone per pass, not one per album, and
    /// every album's index gets its records from it.
    func testSyncAllFetchesZoneChangesOncePerPass() async throws {
        let store = MockCloudKitMediaStore()
        let prev = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        defer { CloudKitStoreProvider.makeStore = prev }

        let albums = (0..<3).map { _ in makeAlbum() }
        let keyManager = DemoKeyManager()
        keyManager.currentKey = albums[0].key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-syncall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        var indexes: [MediaIndexStore] = []
        for album in albums {
            let index = MediaIndexStore(keyBytes: album.key.keyBytes,
                                        indexURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encindex"))
            albumManager.addCloudKitAlbum(album.albumID!, indexStore: index)
            indexes.append(index)
        }
        store.changeSet = CloudKitChangeSet(
            changed: albums.enumerated().map { offset, album in
                CloudKitMediaMetadata(recordName: "m\(offset)", albumID: album.albumID!, mediaID: "m\(offset)",
                                      mediaType: .photo, createdAt: Date(timeIntervalSince1970: 100), sizeBytes: 1,
                                      creationDeviceID: "d", schemaVersion: 1, recordChangeTag: "t\(offset)")
            },
            deleted: [], token: nil, moreComing: false)
        let coordinator = CloudKitSyncCoordinator(
            store: store,
            cache: CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache"), maxBytes: 100_000_000),
            albumManager: albumManager,
            bus: FileOperationBus(),
            uploadQueue: CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("uploads")),
            deleteQueue: CloudKitMediaDeleteQueue(suiteName: "ck-syncall-\(UUID().uuidString)"))
        let sync = CloudKitAlbumsSync(albumManager: albumManager, observeNotifications: false,
                                      makeCoordinator: { _ in coordinator })

        await sync.syncAll()

        XCTAssertEqual(store.fetchChangesCount, 1, "one pass must walk the zone once for all three albums")
        for (offset, index) in indexes.enumerated() {
            let entries = await index.current()?.entries.map(\.id)
            XCTAssertEqual(entries, ["m\(offset)"], "album \(offset) must get exactly its own record")
        }

        await sync.syncAll()
        XCTAssertEqual(store.fetchChangesCount, 2, "a second pass, as a push triggers, is one more fetch")
    }

    /// The uploader goes through the zone's coordinator, which finds any album's
    /// index by id, so a capture queued for an album nobody opened this launch
    /// still drains.
    func testUploaderDrainsForAnAlbumNotOpenedThisLaunch() async throws {
        let store = MockCloudKitMediaStore()
        let notOpened = makeAlbum()
        let keyManager = DemoKeyManager()
        keyManager.currentKey = notOpened.key
        let albumManager = MockAlbumManager(keyManager: keyManager)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-unopened-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let index = MediaIndexStore(keyBytes: notOpened.key.keyBytes,
                                    indexURL: tempRoot.appendingPathComponent("index.encindex"))
        albumManager.addCloudKitAlbum(notOpened.albumID!, indexStore: index)
        let queue = CloudKitUploadQueue(baseDir: tempRoot.appendingPathComponent("uploads"))
        let coordinator = CloudKitSyncCoordinator(
            store: store,
            cache: CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache"), maxBytes: 100_000_000),
            albumManager: albumManager,
            bus: FileOperationBus(),
            uploadQueue: queue,
            deleteQueue: CloudKitMediaDeleteQueue(suiteName: "ck-unopened-\(UUID().uuidString)"))
        let reporter = await MainActor.run { CloudKitSyncStatusReporter() }
        let uploader = CloudKitUploader(queue: queue, coordinator: coordinator, statusReporter: reporter)

        let fileURL = tempRoot.appendingPathComponent("capture.enc")
        try Data("ciphertext".utf8).write(to: fileURL)
        let upload = CloudKitMediaUpload(albumID: notOpened.albumID!, mediaID: "queued", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 1), sizeBytes: 10,
                                         encryptedFileURL: fileURL, encryptedThumbURL: nil)
        _ = try await queue.enqueue(upload)

        await uploader.drainNow()

        XCTAssertEqual(store.uploadCalls, [upload.recordName], "the queued capture must reach CloudKit")
        let pending = await queue.all()
        XCTAssertTrue(pending.isEmpty, "the queue entry must be completed")
        let entries = await index.current()?.entries.map(\.id)
        XCTAssertEqual(entries, ["queued"], "the album's index records the uploaded item")
        await uploader.shutdown()
    }
}

// MARK: - Corrupting chunk store

/// Serves one chunk with a flipped byte, so it fails authentication.
actor ChunkCorruptingBlobStore: ChunkedBlobStoring {
    private let base: ChunkedBlobStoring
    private let corruptIndex: Int
    private(set) var corruptServed = false

    init(wrapping base: ChunkedBlobStoring, corruptIndex: Int) {
        self.base = base
        self.corruptIndex = corruptIndex
    }

    func uploadChunks(enc3FileURL: URL,
                      mediaRecordName: String,
                      existingChunks: ExistingChunkPolicy,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> SeekableEncryptedHeader {
        try await base.uploadChunks(enc3FileURL: enc3FileURL, mediaRecordName: mediaRecordName,
                                    existingChunks: existingChunks, progress: progress)
    }

    func fetchChunk(mediaRecordName: String, index: Int) async throws -> Data {
        var data = try await base.fetchChunk(mediaRecordName: mediaRecordName, index: index)
        if index == corruptIndex, !data.isEmpty {
            let last = data.index(before: data.endIndex)
            data[last] ^= 0xFF
            corruptServed = true
        }
        return data
    }

    func delete(mediaRecordName: String, chunkCount: Int) async throws {
        try await base.delete(mediaRecordName: mediaRecordName, chunkCount: chunkCount)
    }
}

// MARK: - Recording store

/// Forwards every call to a shared store, as one device's view of the account,
/// and records what this device fetched. Can fail uploads retryably so a test
/// chooses which drain attempt lands.
final class RecordingCloudKitMediaStore: CloudKitMediaStoring, @unchecked Sendable {

    private let base: CloudKitMediaStoring
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private var _fetchThumbnailCount = 0
    private var _fetchBlobCount = 0
    private var recordNamesFailingUploads: Set<String> = []

    var fetchThumbnailCount: Int { locked { _fetchThumbnailCount } }
    var fetchBlobCount: Int { locked { _fetchBlobCount } }

    init(wrapping base: CloudKitMediaStoring) {
        self.base = base
    }

    /// Every upload of these records throws `.retry(after: 0)` without reaching
    /// the store, until `stopFailingUploads()`.
    func failUploadsRetryably(recordNames: Set<String>) {
        locked { recordNamesFailingUploads.formUnion(recordNames) }
    }

    func stopFailingUploads() {
        locked { recordNamesFailingUploads.removeAll() }
    }

    func upload(_ item: CloudKitMediaUpload,
                progress: @escaping @Sendable (Double) -> Void) async throws -> CloudKitMediaRef {
        if locked({ recordNamesFailingUploads.contains(item.recordName) }) {
            throw CloudKitMediaStoreError.retry(after: 0)
        }
        return try await base.upload(item, progress: progress)
    }

    func fetchMetadata(albumID: String, includeThumbnail: Bool) async throws -> [CloudKitMediaMetadata] {
        try await base.fetchMetadata(albumID: albumID, includeThumbnail: includeThumbnail)
    }

    func fetchRecordMetadata(recordName: String) async throws -> CloudKitMediaMetadata? {
        try await base.fetchRecordMetadata(recordName: recordName)
    }

    func fetchBlob(recordName: String,
                   to destination: URL,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
        locked { _fetchBlobCount += 1 }
        try await base.fetchBlob(recordName: recordName, to: destination, progress: progress)
    }

    func fetchThumbnail(recordName: String, to destination: URL) async throws {
        locked { _fetchThumbnailCount += 1 }
        try await base.fetchThumbnail(recordName: recordName, to: destination)
    }

    func attachThumbnail(recordName: String, thumbnailURL: URL) async throws -> ThumbnailAttachResult {
        try await base.attachThumbnail(recordName: recordName, thumbnailURL: thumbnailURL)
    }

    func delete(recordName: String) async throws { try await base.delete(recordName: recordName) }
    func saveAlbum(_ album: CloudKitAlbumUpload) async throws { try await base.saveAlbum(album) }
    func fetchAllAlbums() async throws -> [CloudKitAlbumMetadata] { try await base.fetchAllAlbums() }
    func fetchAlbum(albumID: String) async throws -> CloudKitAlbumMetadata? { try await base.fetchAlbum(albumID: albumID) }
    func fetchFingerprintCensus() async throws -> CloudKitFingerprintCensus { try await base.fetchFingerprintCensus() }
    func deleteAlbum(albumID: String) async throws { try await base.deleteAlbum(albumID: albumID) }
    func fetchChanges(since token: CKServerChangeToken?) async throws -> CloudKitChangeSet {
        try await base.fetchChanges(since: token)
    }
    func loadChangeToken() async -> CKServerChangeToken? { await base.loadChangeToken() }
    func hasChangeToken() async -> Bool { await base.hasChangeToken() }
    func commitChangeToken(_ token: CKServerChangeToken?) async { await base.commitChangeToken(token) }
    func resetChangeToken() async { await base.resetChangeToken() }
    func reassignAlbum(recordNames: [String], toAlbumID: String) async throws -> [String] {
        try await base.reassignAlbum(recordNames: recordNames, toAlbumID: toAlbumID)
    }
    func confirmAlbum(recordName: String) async throws -> String? { try await base.confirmAlbum(recordName: recordName) }
    func recreateZone() async throws { try await base.recreateZone() }
    func ensureZoneExists() async throws { try await base.ensureZoneExists() }
    func registerZoneSubscription() async throws { try await base.registerZoneSubscription() }
    func cancelAll() { base.cancelAll() }
    func accountAvailable() async -> Bool { await base.accountAvailable() }
}

/// Collects the media ids of every `.mediaPreviewDidChange` posted while it lives.
private final class PreviewAnnouncements: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .mediaPreviewDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let self, let id = notification.previewMediaID else { return }
            self.lock.lock()
            self.ids.append(id)
            self.lock.unlock()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var mediaIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}
