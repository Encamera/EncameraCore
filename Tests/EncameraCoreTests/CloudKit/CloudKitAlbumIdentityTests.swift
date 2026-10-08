//
//  CloudKitAlbumIdentityTests.swift
//  EncameraCoreTests
//
//  A CloudKit album's identity is its stored `albumID`, not its name: every store
//  keyed by the album stays put across a rename, the `album.json` marker round-trips,
//  and enumeration builds albums (or locked placeholders) from those markers.
//

import Combine
import UIKit
import XCTest
@testable import EncameraCore

final class CloudKitAlbumIdentityTests: XCTestCase {

    private var markerIDs: [String] = []

    override func tearDown() {
        for albumID in markerIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        markerIDs = []
        super.tearDown()
    }

    private func makeKey(_ name: String = "identity-\(UUID().uuidString.prefix(6))") -> PrivateKey {
        PrivateKey(name: name, keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
    }

    private func cloudKitAlbum(name: String = "Identity-\(UUID().uuidString)",
                               key: PrivateKey? = nil,
                               albumID: String = UUID().uuidString) -> Album {
        Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key ?? makeKey(), albumID: albumID)
    }

    private func writeMarker(_ marker: CloudKitAlbumMarker, albumID: String) throws {
        markerIDs.append(albumID)
        try marker.write(albumID: albumID)
    }

    // MARK: - Rename keeps every album-keyed store

    func testRenameLeavesIdentityAndEveryAlbumKeyedLocationUnchanged() {
        var album = cloudKitAlbum(name: "Before")
        let albumID = album.albumID
        let id = album.id
        let cacheFolder = CloudKitStorageModel(album: album).baseURL
        let indexURL = MediaIndexStore.indexURL(for: album)
        let sizeSidecarURL = AlbumSizeSidecar.sidecarURL(for: album)
        let coverSidecarURL = AlbumCoverSidecar.sidecarURL(for: album)
        let namespace = CloudKitFileAccess.storeNamespace(for: album)
        let ciphertext = album.encryptedPathComponent

        album.name = "After"

        XCTAssertNotEqual(album.encryptedPathComponent, ciphertext, "precondition: the name really was re-encrypted")
        XCTAssertEqual(album.albumID, albumID)
        XCTAssertEqual(album.id, id)
        XCTAssertEqual(CloudKitStorageModel(album: album).baseURL, cacheFolder, "blob cache folder")
        XCTAssertEqual(MediaIndexStore.indexURL(for: album), indexURL, "media index")
        XCTAssertEqual(AlbumSizeSidecar.sidecarURL(for: album), sizeSidecarURL, "size sidecar")
        XCTAssertEqual(AlbumCoverSidecar.sidecarURL(for: album), coverSidecarURL, "cover sidecar")
        XCTAssertEqual(CloudKitFileAccess.storeNamespace(for: album), namespace, "change-token namespace")
        XCTAssertEqual(namespace, albumID, "the store namespace is the album id itself")
    }

    func testCloudKitIDIsTheAlbumIDAndLocalIDIsTheName() {
        let key = makeKey()
        let cloud = cloudKitAlbum(name: "Trip", key: key, albumID: "7F1C0B0E-2B8A-4C47-9C1E-2B57D2A1E001")
        XCTAssertEqual(cloud.id, "7F1C0B0E-2B8A-4C47-9C1E-2B57D2A1E001_cloudKit")
        let local = Album(name: "Trip", storageOption: .local, creationDate: Date(), key: key)
        XCTAssertNil(local.albumID)
        XCTAssertEqual(local.id, "Trip_local")
    }

    // MARK: - Equality and hashing

    func testCloudKitAlbumsCompareByAlbumIDNotByNameCiphertext() {
        let key = makeKey()
        let date = Date()
        let albumID = UUID().uuidString
        let first = Album(name: "Same", storageOption: .cloudKit, creationDate: date, key: key, albumID: albumID)
        let second = Album(name: "Same", storageOption: .cloudKit, creationDate: date, key: key, albumID: albumID)
        XCTAssertNotEqual(first.encryptedPathComponent, second.encryptedPathComponent,
                          "precondition: each encryption of a name is different ciphertext")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(Set([first]).union(Set([second])).count, 1, "a set union of two scans de-duplicates")

        var renamed = second
        renamed.name = "Renamed"
        XCTAssertNotEqual(first, renamed, "a rename is still a change a view can see")
        XCTAssertEqual(first.hashValue, renamed.hashValue)

        let other = Album(name: "Same", storageOption: .cloudKit, creationDate: date, key: key,
                          albumID: UUID().uuidString)
        XCTAssertNotEqual(first, other, "two albums that share a name are still two albums")
    }

    // MARK: - Twins

    func testTwinsSetAndClearTheAlbumID() {
        let local = Album(name: "Twin", storageOption: .local, creationDate: Date(), key: makeKey())
        let cloud = Album.cloudKitTwin(of: local, albumID: "twin-id")
        XCTAssertEqual(cloud.storageOption, .cloudKit)
        XCTAssertEqual(cloud.albumID, "twin-id")
        XCTAssertEqual(cloud.name, "Twin")
        XCTAssertEqual(cloud.encryptedPathComponent, local.encryptedPathComponent,
                       "the name ciphertext carries over byte for byte")

        let back = Album.localTwin(of: cloud)
        XCTAssertEqual(back.storageOption, .local)
        XCTAssertNil(back.albumID)
        XCTAssertEqual(back.id, local.id)
    }

    func testCloudKitTwinOfALegacyPlaintextAlbumCarriesRealCiphertext() {
        let key = makeKey()
        let legacy = Album(encryptedName: "Holiday", storageOption: .local, creationDate: Date(), key: key)
        XCTAssertEqual(legacy.encryptedPathComponent, "Holiday", "precondition: a legacy directory name is plaintext")

        let twin = Album.cloudKitTwin(of: legacy, albumID: UUID().uuidString)

        XCTAssertEqual(twin.name, "Holiday")
        XCTAssertEqual(Album.decryptedAlbumName(twin.encryptedPathComponent, key: key), "Holiday",
                       "no plaintext name may become the CloudKit encName")
    }

    // MARK: - album.json

    func testMarkerRoundTrip() throws {
        let albumID = UUID().uuidString
        let marker = CloudKitAlbumMarker(encName: cloudKitAlbum().encryptedPathComponent,
                                         createdAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456),
                                         isHidden: true,
                                         coverMediaID: "cover-media",
                                         keyFingerprint: "fingerprint",
                                         dirty: true)
        try writeMarker(marker, albumID: albumID)

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID), marker)
        XCTAssertEqual(CloudKitAlbumMarker.fileURL(albumID: albumID).lastPathComponent, "album.json")
        XCTAssertEqual(CloudKitAlbumMarker.directoryURL(albumID: albumID).lastPathComponent, albumID,
                       "a UUID names its directory verbatim")
        XCTAssertTrue(CloudKitAlbumMarker.all().contains { $0.albumID == albumID && $0.marker == marker })

        try CloudKitAlbumMarker.remove(albumID: albumID)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertFalse(CloudKitAlbumMarker.all().contains { $0.albumID == albumID })
    }

    /// An album id that is not a UUID can hold `/`, which a single path component
    /// cannot.
    func testMarkerForAnIDThatIsNotPathSafeRoundTrips() throws {
        let albumID = "ab/cd+ef==\(UUID().uuidString.prefix(4))"
        let marker = CloudKitAlbumMarker(encName: cloudKitAlbum().encryptedPathComponent, createdAt: Date())
        try writeMarker(marker, albumID: albumID)

        XCTAssertEqual(CloudKitAlbumMarker.directoryURL(albumID: albumID).deletingLastPathComponent().standardizedFileURL,
                       CloudKitStorageModel.albumsURL.standardizedFileURL,
                       "the marker directory sits directly under the marker root")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID), marker)
        XCTAssertTrue(CloudKitAlbumMarker.all().contains { $0.albumID == albumID })
    }

    // MARK: - Marker location

    /// iOS purges `Library/Caches` under storage pressure, and a marker is the only
    /// record of an album that has not been published.
    func testMarkerRootIsNotUnderCaches() throws {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let cachesPath = caches.standardizedFileURL.resolvingSymlinksInPath().path
        for url in [CloudKitAlbumMarker.rootDirectoryURL,
                    CloudKitAlbumMarker.directoryURL(albumID: UUID().uuidString),
                    CloudKitStorageModel.albumsURL] {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            XCTAssertFalse(path.hasPrefix(cachesPath + "/"), "\(path) is under Caches")
        }
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first)
        XCTAssertTrue(CloudKitAlbumMarker.rootDirectoryURL.standardizedFileURL.path
            .hasPrefix(appSupport.standardizedFileURL.path + "/"))
    }

    // MARK: - Enumeration

    private func makeManager(keys: [PrivateKey], currentKey: PrivateKey?) -> AlbumManager {
        let keyManager = DemoKeyManager(keys: keys)
        keyManager.currentKey = currentKey
        return AlbumManager(keyManager: keyManager, syncedDataStore: nil)
    }

    func testEnumerationBuildsTheAlbumFromItsMarker() throws {
        let key = makeKey()
        let albumID = UUID().uuidString
        let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let album = Album(name: "Enumerated-\(UUID().uuidString)", storageOption: .cloudKit,
                          creationDate: createdAt, key: key, albumID: albumID)
        try writeMarker(CloudKitAlbumMarker(album: album, isHidden: false), albumID: albumID)
        let manager = makeManager(keys: [makeKey(), key], currentKey: makeKey())

        let found = try XCTUnwrap(manager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.albumID == albumID })

        XCTAssertEqual(found.name, album.name)
        XCTAssertEqual(found.storageOption, .cloudKit)
        XCTAssertEqual(found.key.keyBytes, key.keyBytes, "the key that opens the name, not the current key")
        XCTAssertEqual(found.creationDate, createdAt, "the creation date comes from album.json")
        XCTAssertEqual(found.id, album.id)
        XCTAssertFalse(manager.lockedAlbums.contains { $0.encryptedDirectoryName == album.encryptedPathComponent })
    }

    func testEnumerationMakesALockedPlaceholderWhenNoKeyOpensTheName() throws {
        let absentKey = makeKey()
        let albumID = UUID().uuidString
        let album = cloudKitAlbum(key: absentKey, albumID: albumID)
        try writeMarker(CloudKitAlbumMarker(album: album, isHidden: false), albumID: albumID)
        let held = makeKey()
        let manager = makeManager(keys: [held], currentKey: held)

        let albums = manager.fetchAlbumsFromSources(includingHidden: true)

        XCTAssertFalse(albums.contains { $0.albumID == albumID }, "a locked album is never given another key")
        let placeholder = try XCTUnwrap(manager.lockedAlbums.first {
            $0.encryptedDirectoryName == album.encryptedPathComponent
        })
        XCTAssertEqual(placeholder.storageOption, .cloudKit)
        XCTAssertEqual(placeholder.creationDate, album.creationDate)
    }

    func testEnumerationNeverAttachesTheCurrentKeyToAPlaintextMarkerName() throws {
        let albumID = UUID().uuidString
        try writeMarker(CloudKitAlbumMarker(encName: "Plaintext-\(UUID().uuidString)", createdAt: Date()),
                        albumID: albumID)
        let held = makeKey()
        let manager = makeManager(keys: [held], currentKey: held)

        XCTAssertFalse(manager.fetchAlbumsFromSources(includingHidden: true).contains { $0.albumID == albumID })
    }

    /// "Free up space" on the storage screen empties the blob cache, and must leave
    /// every CloudKit album listed.
    func testFreeUpSpaceKeepsEveryCloudKitAlbumListed() async throws {
        let key = makeKey()
        let albums = (0..<2).map { _ in cloudKitAlbum(key: key) }
        let cache = CloudKitBlobCache()
        var blobs: [URL] = []
        for album in albums {
            let albumID = try XCTUnwrap(album.albumID)
            try writeMarker(CloudKitAlbumMarker(album: album, isHidden: false), albumID: albumID)
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("free-\(UUID().uuidString)")
            try Data(repeating: 0xEE, count: 64).write(to: source)
            blobs.append(try await cache.store(recordName: "\(UUID().uuidString)#0", changeTag: "t",
                                               albumID: albumID, from: source))
        }
        let manager = makeManager(keys: [key], currentKey: key)
        let pendingUploads = CloudKitUploadQueue(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("free-uploads-\(UUID().uuidString)", isDirectory: true))

        try await cache.freeUpSpace(pendingUploads: pendingUploads)

        for album in albums {
            let albumID = try XCTUnwrap(album.albumID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: CloudKitAlbumMarker.fileURL(albumID: albumID).path),
                          "album.json must survive freeing space")
            let listed = manager.fetchAlbumsFromSources(includingHidden: true).first { $0.albumID == albumID }
            XCTAssertEqual(listed?.name, album.name, "the album must still be listed")
        }
        for blob in blobs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path), "the cached ciphertext must be freed")
        }
    }

    // MARK: - Create and finalize resolution

    func testCreateMintsAnAlbumIDAndEnumeratesBackUnderIt() throws {
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in InMemoryCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }
        let key = makeKey()
        let manager = makeManager(keys: [key], currentKey: key)

        let created = try manager.create(name: "Created-\(UUID().uuidString)", storageOption: .cloudKit)
        let albumID = try XCTUnwrap(created.albumID)
        markerIDs.append(albumID)
        defer { try? FileManager.default.removeItem(at: CloudKitStorageModel(album: created).baseURL) }

        XCTAssertNotNil(UUID(uuidString: albumID), "a created CloudKit album mints a UUID")
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: key), created.name)
        let found = manager.fetchAlbumsFromSources(includingHidden: true).first { $0.albumID == albumID }
        XCTAssertEqual(found?.name, created.name)
        XCTAssertEqual(found?.id, created.id)
    }

    func testFinalizedResolutionFindsTheCloudKitAlbumByNameAndKey() throws {
        let key = makeKey()
        let local = Album(name: "Moved-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: key)
        XCTAssertNil(CloudKitAlbumMarker.albumID(matching: local))

        let albumID = UUID().uuidString
        try writeMarker(CloudKitAlbumMarker(album: Album.cloudKitTwin(of: local, albumID: albumID), isHidden: false),
                        albumID: albumID)

        XCTAssertEqual(CloudKitAlbumMarker.albumID(matching: local), albumID)
        let otherKey = Album(name: local.name, storageOption: .local, creationDate: Date(), key: makeKey())
        XCTAssertNil(CloudKitAlbumMarker.albumID(matching: otherKey), "the same name under another key is another album")
    }

    // MARK: - Adoption

    /// An adopted album is the record's album: its `album.json` carries the record's
    /// `encName` byte for byte and its metadata, under the record's id.
    func testAdoptWritesTheMarkerFromTheRecord() throws {
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in InMemoryCloudKitMediaStore() }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }
        let key = makeKey()
        let name = "Adopted-\(UUID().uuidString)"
        let encName = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key).encryptedPathComponent
        let albumID = UUID().uuidString
        markerIDs.append(albumID)
        defer { UserDefaults.standard.removeObject(forKey: "isAlbumHidden(name: \"\(name)\")") }
        let createdAt = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let record = CloudKitAlbumMetadata(albumID: albumID,
                                           encName: encName,
                                           createdAt: createdAt,
                                           isHidden: true,
                                           schemaVersion: CloudKitSchema.currentSchemaVersion,
                                           keyFingerprint: key.keychainLabel,
                                           recordChangeTag: "tag",
                                           coverMediaID: "cover-1")
        let manager = makeManager(keys: [key], currentKey: key)

        manager.adoptCloudKitAlbum(record: record, key: key)

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(marker, CloudKitAlbumMarker(encName: encName, createdAt: createdAt, isHidden: true,
                                                   coverMediaID: "cover-1", keyFingerprint: key.keychainLabel,
                                                   dirty: false))
        let found = try XCTUnwrap(manager.fetchAlbumsFromSources(includingHidden: true).first { $0.albumID == albumID })
        XCTAssertEqual(found.name, name)
        XCTAssertEqual(found.encryptedPathComponent, encName)
    }

    // MARK: - Hidden and cover live in album.json and on the record

    /// An album manager whose name-keyed synced store sits on an in-memory iCloud
    /// key-value store, so a test can see anything written to it.
    private struct MetadataHarness {
        let manager: AlbumManager
        let store: MockCloudKitMediaStore
        let kvs: MockKeyValueStore
        let syncedStore: AlbumsSyncedStore
        let album: Album
    }

    private func makeMetadataHarness(name: String = "Meta-\(UUID().uuidString)",
                                     isHidden: Bool = false,
                                     coverMediaID: String? = nil,
                                     function: String = #function) throws -> MetadataHarness {
        let key = makeKey()
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        let kvs = MockKeyValueStore()
        let dataStore = SyncedDataStore(keyManager: keyManager,
                                        defaults: makeIsolatedDefaults(function),
                                        cloudStore: kvs)
        let album = cloudKitAlbum(name: name, key: key)
        try writeMarker(CloudKitAlbumMarker(album: album, isHidden: isHidden, coverMediaID: coverMediaID),
                        albumID: album.albumID!)
        let store = MockCloudKitMediaStore()
        let priorMakeStore = CloudKitStoreProvider.makeStore
        CloudKitStoreProvider.makeStore = { _ in store }
        let priorToggle = FeatureToggle.isEnabled(feature: .cloudKitStorage)
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        addTeardownBlock {
            CloudKitStoreProvider.makeStore = priorMakeStore
            FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: priorToggle)
        }
        return MetadataHarness(manager: AlbumManager(keyManager: keyManager, syncedDataStore: dataStore),
                               store: store,
                               kvs: kvs,
                               syncedStore: AlbumsSyncedStore(store: dataStore),
                               album: album)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func assertNameKeyedSettingsUntouched(_ harness: MetadataHarness,
                                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(harness.kvs.storage.isEmpty, "nothing reached iCloud key-value storage", file: file, line: line)
        XCTAssertNil(try harness.syncedStore.fetchAlbum(name: harness.album.name),
                     "no AlbumsSyncedStore entry under the album's name", file: file, line: line)
        let legacy = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
        XCTAssertNil(legacy.object(forKey: "isAlbumHidden(name: \"\(harness.album.name)\")"), file: file, line: line)
        XCTAssertNil(legacy.object(forKey: "albumCoverImage(albumName: \"\(harness.album.name)\")"), file: file, line: line)
    }

    func testHidingACloudKitAlbumWritesAlbumJSONAndSavesTheRecordWithoutTheSyncedStore() async throws {
        let harness = try makeMetadataHarness()
        let albumID = harness.album.albumID!

        harness.manager.setIsAlbumHidden(true, album: harness.album)

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.isHidden, true)
        XCTAssertTrue(harness.manager.isAlbumHidden(harness.album))
        XCTAssertFalse(harness.manager.fetchAlbumsFromSources(includingHidden: false).contains { $0.albumID == albumID })
        XCTAssertTrue(harness.manager.fetchAlbumsFromSources(includingHidden: true).contains { $0.albumID == albumID })
        let saved = await waitUntil { harness.store.savedAlbumCalls.count == 1 }
        XCTAssertTrue(saved, "the album record is saved")
        let upload = try XCTUnwrap(harness.store.savedAlbumCalls.first)
        XCTAssertEqual(upload.albumID, albumID)
        XCTAssertTrue(upload.isHidden)
        XCTAssertEqual(upload.encName, harness.album.encryptedPathComponent)
        let cleaned = await waitUntil { CloudKitAlbumMarker.read(albumID: albumID)?.dirty == false }
        XCTAssertTrue(cleaned, "a saved change leaves album.json clean")
        try assertNameKeyedSettingsUntouched(harness)
    }

    func testSettingACloudKitAlbumCoverWritesAlbumJSONAndSavesTheRecordWithoutTheSyncedStore() async throws {
        let harness = try makeMetadataHarness()
        let albumID = harness.album.albumID!

        harness.manager.setAlbumCoverImage(album: harness.album,
                                           image: InteractableMedia<EncryptedMedia>(emptyWithType: .stillPhoto, id: "cover-7"))

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.coverMediaID, "cover-7")
        XCTAssertEqual(harness.manager.getAlbumCoverImageId(album: harness.album), "cover-7")
        let saved = await waitUntil { harness.store.savedAlbumCalls.count == 1 }
        XCTAssertTrue(saved, "the album record is saved")
        XCTAssertEqual(harness.store.savedAlbumCalls.first?.coverMediaID, "cover-7")
        let cleaned = await waitUntil { CloudKitAlbumMarker.read(albumID: albumID)?.dirty == false }
        XCTAssertTrue(cleaned)
        try assertNameKeyedSettingsUntouched(harness)
    }

    /// A turned-off cover stays `"none"` for callers and in album.json, and goes to the
    /// record as no cover; a reset clears it.
    func testRemovingAndResettingACloudKitAlbumCoverKeepTheNoneSentinel() async throws {
        let harness = try makeMetadataHarness(coverMediaID: "cover-1")
        let albumID = harness.album.albumID!

        harness.manager.removeAlbumCover(album: harness.album)

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.coverMediaID, "none")
        XCTAssertEqual(harness.manager.getAlbumCoverImageId(album: harness.album), "none")
        XCTAssertTrue(harness.manager.isAlbumCoverImageDisabled(album: harness.album))
        let removedSaved = await waitUntil { harness.store.savedAlbumCalls.count == 1 }
        XCTAssertTrue(removedSaved)
        XCTAssertNil(harness.store.savedAlbumCalls.first?.coverMediaID, "the record cannot reference a disabled cover")
        _ = await waitUntil { CloudKitAlbumMarker.read(albumID: albumID)?.dirty == false }

        harness.manager.resetAlbumCover(album: harness.album)

        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID)?.coverMediaID)
        XCTAssertNil(harness.manager.getAlbumCoverImageId(album: harness.album))
        XCTAssertFalse(harness.manager.isAlbumCoverImageDisabled(album: harness.album))
        let resetSaved = await waitUntil { harness.store.savedAlbumCalls.count == 2 }
        XCTAssertTrue(resetSaved)
        XCTAssertNil(harness.store.savedAlbumCalls.last?.coverMediaID)
        try assertNameKeyedSettingsUntouched(harness)
    }

    func testAFailedHiddenOrCoverSaveLeavesAlbumJSONDirty() async throws {
        let harness = try makeMetadataHarness()
        let albumID = harness.album.albumID!
        harness.store.saveAlbumError = CloudKitMediaStoreError.retry(after: 1)

        harness.manager.setIsAlbumHidden(true, album: harness.album)
        let hideAttempted = await waitUntil { harness.store.saveAlbumAttemptCount == 1 }
        XCTAssertTrue(hideAttempted)
        harness.manager.setAlbumCoverImage(album: harness.album,
                                           image: InteractableMedia<EncryptedMedia>(emptyWithType: .stillPhoto, id: "cover-9"))
        let coverAttempted = await waitUntil { harness.store.saveAlbumAttemptCount == 2 }
        XCTAssertTrue(coverAttempted)
        try await Task.sleep(nanoseconds: 100_000_000)

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertTrue(marker.dirty, "the reconciler retries a change the record never got")
        XCTAssertTrue(marker.isHidden)
        XCTAssertEqual(marker.coverMediaID, "cover-9")
        XCTAssertEqual(marker.dirtyFields, [.hidden, .cover],
                       "only the fields the user changed are pending, so another device's rename still applies")
        XCTAssertTrue(harness.store.savedAlbumCalls.isEmpty)
    }

    func testCreateWritesAlbumJSONMakesTheCacheFolderAndSavesTheRecordUnderTheMintedID() async throws {
        let harness = try makeMetadataHarness()
        let name = "Created-\(UUID().uuidString)"

        let created = try harness.manager.create(name: name, storageOption: .cloudKit)
        let albumID = try XCTUnwrap(created.albumID)
        markerIDs.append(albumID)
        let cacheFolder = CloudKitStorageModel(album: created).baseURL
        defer { try? FileManager.default.removeItem(at: cacheFolder) }

        XCTAssertNotNil(UUID(uuidString: albumID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFolder.path), "the blob cache folder")
        XCTAssertEqual(cacheFolder.lastPathComponent, CloudKitBlobCache.albumFolderName(albumID))
        let saved = await waitUntil { harness.store.savedAlbumCalls.contains { $0.albumID == albumID } }
        XCTAssertTrue(saved, "the record is saved under the minted id")
        let upload = try XCTUnwrap(harness.store.savedAlbumCalls.first { $0.albumID == albumID })
        XCTAssertEqual(Album.decryptedAlbumName(upload.encName, key: created.key), name)
        XCTAssertFalse(upload.isHidden)
        let cleaned = await waitUntil { CloudKitAlbumMarker.read(albumID: albumID)?.dirty == false }
        XCTAssertTrue(cleaned)
        XCTAssertEqual(try harness.manager.create(name: name, storageOption: .cloudKit).albumID, albumID,
                       "a duplicate name returns the existing album")
    }

    func testAdoptKeepsTheHiddenFlagInAlbumJSONAndLeavesTheSyncedStoreAlone() throws {
        let harness = try makeMetadataHarness()
        let key = harness.album.key
        let name = "AdoptedHidden-\(UUID().uuidString)"
        let albumID = UUID().uuidString
        markerIDs.append(albumID)
        let record = CloudKitAlbumMetadata(albumID: albumID,
                                           encName: Album(name: name, storageOption: .cloudKit,
                                                          creationDate: Date(), key: key).encryptedPathComponent,
                                           createdAt: Date(),
                                           isHidden: true,
                                           schemaVersion: CloudKitSchema.currentSchemaVersion,
                                           keyFingerprint: key.keychainLabel,
                                           recordChangeTag: "tag")

        harness.manager.adoptCloudKitAlbum(record: record, key: key)

        let adopted = try XCTUnwrap(harness.manager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.albumID == albumID })
        XCTAssertTrue(harness.manager.isAlbumHidden(adopted))
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.dirty, false, "adoption changes nothing to push")
        XCTAssertTrue(harness.kvs.storage.isEmpty)
        XCTAssertNil(try harness.syncedStore.fetchAlbum(name: name))
    }

    /// Delete removes everything keyed by the album id, the cover sidecar included,
    /// and leaves settings a same-named local album keeps under that name.
    func testDeleteRemovesAlbumJSONAndTheCoverSidecarButNotNameKeyedSettings() async throws {
        let harness = try makeMetadataHarness(coverMediaID: "cover-3")
        let album = harness.album
        let albumID = album.albumID!
        try await AlbumCoverSidecar(album: album).setCoverMediaID("cover-3")
        let coverSidecarURL = AlbumCoverSidecar.sidecarURL(for: album)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverSidecarURL.path), "precondition")
        try harness.syncedStore.setAlbumHidden(album.name, isHidden: true)

        try harness.manager.delete(album: album)

        XCTAssertFalse(FileManager.default.fileExists(atPath: coverSidecarURL.path), "the cover sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudKitAlbumMarker.directoryURL(albumID: albumID).path),
                       "the album.json directory")
        XCTAssertEqual(try harness.syncedStore.fetchAlbum(name: album.name)?.isHidden, true,
                       "a same-named local album's hidden flag survives")
        let deleted = await waitUntil { harness.store.deletedAlbumCalls.contains(albumID) }
        XCTAssertTrue(deleted, "the record is deleted under the album id")
    }

    func testRemoteDeletionRemovesAlbumJSONAndTheCoverSidecar() async throws {
        let harness = try makeMetadataHarness()
        let album = harness.album
        try await AlbumCoverSidecar(album: album).setCoverMediaID("cover-4")
        let coverSidecarURL = AlbumCoverSidecar.sidecarURL(for: album)

        harness.manager.applyRemoteAlbumDeletion(album: album)

        XCTAssertFalse(FileManager.default.fileExists(atPath: coverSidecarURL.path))
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: album.albumID!))
        XCTAssertTrue(harness.store.deletedAlbumCalls.isEmpty, "a remote delete leaves the server alone")
    }

    // MARK: - A deleted album's previews leave the disk with it

    /// Writes `mediaIDs` into the album's media index and a preview file for each,
    /// and returns the preview URLs.
    private func seedIndexedItemsWithPreviews(_ mediaIDs: [String], in album: Album) async throws -> [URL] {
        let entries = mediaIDs.map {
            MediaIndexEntry(id: $0, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: Date(), dateTaken: nil, subtypeRawValue: 0)
        }
        try await MediaIndexStore(album: album).save(MediaIndex(entries: entries))
        let indexURL = MediaIndexStore.indexURL(for: album)
        addTeardownBlock { try? FileManager.default.removeItem(at: indexURL) }
        return try mediaIDs.map { try writePreview(forMediaID: $0) }
    }

    private func writePreview(forMediaID mediaID: String) throws -> URL {
        let previewURL = CloudKitStorageModel.previewURL(forMediaID: mediaID)
        try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("preview".utf8).write(to: previewURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: previewURL) }
        return previewURL
    }

    /// The album can be deleted before this device's media sync has seen the
    /// cascaded `EncMedia` deletions. The album's index goes with it, so no later
    /// sync can find the items again: the delete itself has to take their previews.
    func testRemoteDeletionRemovesThePreviewOfEveryIndexedItem() async throws {
        let harness = try makeMetadataHarness()
        let album = harness.album
        let previews = try await seedIndexedItemsWithPreviews(["rd-\(UUID().uuidString)", "rd-\(UUID().uuidString)"],
                                                              in: album)
        let unrelated = try writePreview(forMediaID: "unrelated-\(UUID().uuidString)")

        harness.manager.applyRemoteAlbumDeletion(album: album)

        for preview in previews {
            XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path),
                           "\(preview.lastPathComponent) belonged to the deleted album")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "another item's preview stays")
    }

    /// A move between CloudKit albums keeps the media id, and so the preview file.
    /// A deleted album whose index still lists a moved item must leave that preview
    /// to the album now holding it.
    func testRemoteDeletionKeepsAPreviewAnotherCloudKitAlbumStillIndexes() async throws {
        let harness = try makeMetadataHarness()
        let album = harness.album
        let other = try addCloudKitAlbum(to: harness)
        let shared = "moved-\(UUID().uuidString)"
        let previews = try await seedIndexedItemsWithPreviews([shared, "rd-\(UUID().uuidString)"], in: album)
        _ = try await seedIndexedItemsWithPreviews([shared], in: other)

        harness.manager.applyRemoteAlbumDeletion(album: album)

        XCTAssertTrue(FileManager.default.fileExists(atPath: previews[0].path),
                      "the moved item's preview is still \(other.name)'s")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previews[1].path))
    }

    func testDeleteRemovesThePreviewOfEveryIndexedItem() async throws {
        let harness = try makeMetadataHarness()
        let album = harness.album
        let previews = try await seedIndexedItemsWithPreviews(["ld-\(UUID().uuidString)", "ld-\(UUID().uuidString)"],
                                                              in: album)

        try harness.manager.delete(album: album)

        for preview in previews {
            XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path),
                           "\(preview.lastPathComponent) belonged to the deleted album")
        }
    }

    // MARK: - Moving an album's cover item to another album

    private static func tinyPNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData() ?? Data()
    }

    /// A second CloudKit album on the harness's manager, under the same key.
    private func addCloudKitAlbum(to harness: MetadataHarness, coverMediaID: String? = nil) throws -> Album {
        let album = cloudKitAlbum(name: "MoveTarget-\(UUID().uuidString)", key: harness.album.key)
        try writeMarker(CloudKitAlbumMarker(album: album, isHidden: false, coverMediaID: coverMediaID),
                        albumID: album.albumID!)
        return album
    }

    /// A photo record `mediaID` in `albumID`, as the server holds it.
    private func seedPhotoRecord(_ store: MockCloudKitMediaStore, mediaID: String, albumID: String) {
        store.metadataToReturn.append(
            CloudKitMediaMetadata(recordName: CloudKitFileAccess.componentRecordName(mediaID: mediaID, type: .photo),
                                  albumID: albumID, mediaID: mediaID, mediaType: .photo, createdAt: Date(),
                                  sizeBytes: 100, creationDeviceID: "d", schemaVersion: 1,
                                  keyFingerprint: "", recordChangeTag: "t1"))
    }

    private func cloudKitPhoto(_ mediaID: String, in album: Album) throws -> InteractableMedia<EncryptedMedia> {
        try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: URL(fileURLWithPath: "/cloudkit/\(album.albumID!)/\(mediaID)"),
                           mediaType: .photo, id: mediaID)
        ])
    }

    @MainActor
    private func move(_ media: [InteractableMedia<EncryptedMedia>], from source: Album, to target: Album,
                      with manager: AlbumManager) async throws -> MoveResult {
        let taskManager = BackgroundTaskManager()
        defer { taskManager.clearAllTasks() }
        let handler = FileMoveHandler(taskManager: taskManager)
        handler.configure(albumManager: manager)
        return try await handler.startMove(media: media, sourceAlbumId: source.id, targetAlbum: target)
    }

    private func isSaveAlbum(_ call: MockCloudKitMediaStore.Call, _ albumID: String) -> Bool {
        call == .saveAlbum(albumID: albumID)
    }

    /// The source album's `album.json` drops the cover, stays dirty until the record
    /// takes it, and the record push comes after the server-side move.
    @MainActor
    func testMovingACloudKitAlbumsCoverItemToAnotherCloudKitAlbumClearsItsCoverAndPushesTheRecord() async throws {
        let harness = try makeMetadataHarness(coverMediaID: "cover-ck")
        let source = harness.album
        let sourceID = source.albumID!
        let target = try addCloudKitAlbum(to: harness, coverMediaID: "target-cover")
        seedPhotoRecord(harness.store, mediaID: "cover-ck", albumID: sourceID)
        seedPhotoRecord(harness.store, mediaID: "stays", albumID: sourceID)
        try await AlbumCoverSidecar(album: source).setCoverMediaID("cover-ck")
        harness.store.saveAlbumError = CloudKitMediaStoreError.retry(after: 1)

        let result = try await move([try cloudKitPhoto("cover-ck", in: source)], from: source, to: target,
                                    with: harness.manager)

        XCTAssertEqual(result.successCount, 1, "precondition: the cover item moved")
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: sourceID))
        XCTAssertNil(marker.coverMediaID, "the source album falls back to its default cover")
        XCTAssertTrue(marker.dirty, "album.json stays dirty until the record takes the change")
        XCTAssertNil(harness.manager.getAlbumCoverImageId(album: source))
        let pushed = await waitUntil { harness.store.callOrder.contains { self.isSaveAlbum($0, sourceID) } }
        XCTAssertTrue(pushed, "the source album's record push is attempted")
        let order = harness.store.callOrder
        let reassigned = try XCTUnwrap(order.firstIndex { if case .reassignAlbum = $0 { return true }; return false })
        let saved = try XCTUnwrap(order.lastIndex { isSaveAlbum($0, sourceID) })
        XCTAssertLessThan(reassigned, saved, "the cover is reset only after the move is committed")
        let sidecarCover = await AlbumCoverSidecar(album: source).coverMediaID()
        XCTAssertNil(sidecarCover, "no cached copy of the old cover survives to be shown")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: target.albumID!)?.coverMediaID, "target-cover",
                       "only the source album's cover changes")
    }

    @MainActor
    func testMovingACloudKitItemThatIsNotTheCoverLeavesTheCoverAlone() async throws {
        let harness = try makeMetadataHarness(coverMediaID: "cover-ck")
        let source = harness.album
        let target = try addCloudKitAlbum(to: harness)
        seedPhotoRecord(harness.store, mediaID: "other", albumID: source.albumID!)

        let result = try await move([try cloudKitPhoto("other", in: source)], from: source, to: target,
                                    with: harness.manager)

        XCTAssertEqual(result.successCount, 1, "precondition: the item moved")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: source.albumID!)?.coverMediaID, "cover-ck")
        XCTAssertFalse(harness.store.callOrder.contains { isSaveAlbum($0, source.albumID!) })
    }

    @MainActor
    func testMovingItemsOutOfACloudKitAlbumWhoseCoverIsTurnedOffKeepsItTurnedOff() async throws {
        let harness = try makeMetadataHarness(coverMediaID: CloudKitAlbumMarker.disabledCoverID)
        let source = harness.album
        let target = try addCloudKitAlbum(to: harness)
        seedPhotoRecord(harness.store, mediaID: "item", albumID: source.albumID!)

        let result = try await move([try cloudKitPhoto("item", in: source)], from: source, to: target,
                                    with: harness.manager)

        XCTAssertEqual(result.successCount, 1, "precondition: the item moved")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: source.albumID!)?.coverMediaID,
                       CloudKitAlbumMarker.disabledCoverID)
        XCTAssertTrue(harness.manager.isAlbumCoverImageDisabled(album: source))
    }

    @MainActor
    func testACloudKitCoverItemThatFailsToMoveStaysTheCover() async throws {
        let harness = try makeMetadataHarness(coverMediaID: "cover-ck")
        let source = harness.album
        let target = try addCloudKitAlbum(to: harness)
        seedPhotoRecord(harness.store, mediaID: "cover-ck", albumID: source.albumID!)
        harness.store.reassignFailures = [CloudKitFileAccess.componentRecordName(mediaID: "cover-ck", type: .photo)]

        let result = try await move([try cloudKitPhoto("cover-ck", in: source)], from: source, to: target,
                                    with: harness.manager)

        XCTAssertEqual(result.failureCount, 1, "precondition: the move failed")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: source.albumID!)?.coverMediaID, "cover-ck")
        XCTAssertFalse(harness.store.callOrder.contains { isSaveAlbum($0, source.albumID!) })
    }

    /// A local album keeps its cover in `AlbumsSyncedStore`, under its name.
    @MainActor
    func testMovingALocalAlbumsCoverItemToAnotherLocalAlbumFallsBackToTheDefaultCover() async throws {
        let harness = try makeMetadataHarness()
        let manager = harness.manager
        let source = try manager.create(name: "CoverSource-\(UUID().uuidString)", storageOption: .local)
        let target = try manager.create(name: "CoverTarget-\(UUID().uuidString)", storageOption: .local)
        defer {
            try? FileManager.default.removeItem(at: source.storageURL)
            try? FileManager.default.removeItem(at: target.storageURL)
        }
        let backend = DiskMediaBackend()
        await backend.configure(for: source, albumManager: manager)
        var saved: [InteractableMedia<EncryptedMedia>] = []
        for _ in 0..<2 {
            let photo = try InteractableMedia(underlyingMedia: [
                CleartextMedia(source: .data(Self.tinyPNG()), mediaType: .photo, id: UUID().uuidString)
            ])
            let encrypted = try await backend.save(media: photo, metadata: nil, progress: { _ in })
            saved.append(try XCTUnwrap(encrypted))
        }
        manager.setAlbumCoverImage(album: source, image: saved[0])
        manager.setAlbumCoverImage(album: target, image: try cloudKitPhoto("target-cover", in: harness.album))
        XCTAssertEqual(try harness.syncedStore.getCoverImageId(source.name), saved[0].id, "precondition")

        let result = try await move([saved[0]], from: source, to: target, with: manager)

        XCTAssertEqual(result.successCount, 1, "precondition: the cover item moved")
        XCTAssertNil(manager.getAlbumCoverImageId(album: source), "the source album falls back to its default cover")
        XCTAssertNil(try harness.syncedStore.getCoverImageId(source.name))
        XCTAssertEqual(manager.getAlbumCoverImageId(album: target), "target-cover", "only the source album's cover changes")
    }

    // MARK: - Rename is a field update

    private final class StoreIDLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }
        func append(_ id: String) { lock.lock(); _ids.append(id); lock.unlock() }
    }

    /// Writes a placeholder file at `url` so a test can see whether anything moved
    /// or deleted it.
    private func placeFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    private func makeLocalAlbum(_ manager: AlbumManager, name: String) throws -> Album {
        let album = try manager.create(name: name, storageOption: .local)
        addTeardownBlock { try? FileManager.default.removeItem(at: album.storageURL) }
        return album
    }

    func testCloudKitRenameSavesOneRecordAndKeepsEveryAlbumKeyedLocation() async throws {
        let harness = try makeMetadataHarness()
        let album = harness.album
        let albumID = album.albumID!
        let requestedStoreIDs = StoreIDLog()
        let store = harness.store
        CloudKitStoreProvider.makeStore = { id in
            requestedStoreIDs.append(id)
            return store
        }
        let cacheFolder = CloudKitStorageModel(album: album).baseURL
        let cachedBlob = cacheFolder.appendingPathComponent("blob-1")
        let indexURL = MediaIndexStore.indexURL(for: album)
        let sizeSidecarURL = AlbumSizeSidecar.sidecarURL(for: album)
        let coverSidecarURL = AlbumCoverSidecar.sidecarURL(for: album)
        for url in [cachedBlob, indexURL, sizeSidecarURL, coverSidecarURL] {
            try placeFile(at: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheFolder) }
        let namespace = CloudKitFileAccess.storeNamespace(for: album)
        harness.manager.currentAlbum = album
        var renamedBroadcasts: [Album] = []
        let subscription = harness.manager.albumOperationPublisher.sink { operation in
            if case .albumRenamed(let renamed) = operation { renamedBroadcasts.append(renamed) }
        }
        defer { subscription.cancel() }
        let newName = "Renamed-\(UUID().uuidString)"

        let renamed = try harness.manager.renameAlbum(album: album, to: newName)

        XCTAssertEqual(renamed.name, newName)
        XCTAssertEqual(renamed.albumID, albumID)
        XCTAssertEqual(renamed.id, album.id)
        XCTAssertEqual(renamed.storageOption, .cloudKit)
        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(marker.encName, renamed.encryptedPathComponent, "album.json holds the new name")
        XCTAssertEqual(Album.decryptedAlbumName(marker.encName, key: album.key), newName)
        XCTAssertEqual(harness.manager.currentAlbum?.albumID, albumID)
        XCTAssertEqual(harness.manager.currentAlbum?.name, newName)
        XCTAssertEqual(renamedBroadcasts.map(\.name), [newName])
        let listed = try XCTUnwrap(harness.manager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.albumID == albumID })
        XCTAssertEqual(listed.name, newName, "enumeration finds the album under its new name")
        XCTAssertFalse(harness.manager.fetchAlbumsFromSources(includingHidden: true).contains { $0.name == album.name })

        XCTAssertEqual(CloudKitStorageModel(album: renamed).baseURL, cacheFolder, "blob cache folder")
        XCTAssertEqual(MediaIndexStore.indexURL(for: renamed), indexURL, "media index")
        XCTAssertEqual(AlbumSizeSidecar.sidecarURL(for: renamed), sizeSidecarURL, "size sidecar")
        XCTAssertEqual(AlbumCoverSidecar.sidecarURL(for: renamed), coverSidecarURL, "cover sidecar")
        XCTAssertEqual(CloudKitFileAccess.storeNamespace(for: renamed), namespace, "change-token namespace")
        for url in [cachedBlob, indexURL, sizeSidecarURL, coverSidecarURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) stays put")
        }

        let cleaned = await waitUntil { CloudKitAlbumMarker.read(albumID: albumID)?.dirty == false }
        XCTAssertTrue(cleaned, "a saved rename leaves album.json clean")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(harness.store.savedAlbumCalls.count, 1, "exactly one album record save")
        let upload = try XCTUnwrap(harness.store.savedAlbumCalls.first)
        XCTAssertEqual(upload.albumID, albumID, "the record keeps its name")
        XCTAssertEqual(upload.encName, renamed.encryptedPathComponent)
        XCTAssertEqual(harness.store.fetchMetadataCalls.count, 0)
        XCTAssertEqual(harness.store.reassignCalls.count, 0)
        XCTAssertEqual(harness.store.deletedAlbumCalls.count, 0)
        XCTAssertEqual(harness.store.deleteCalls.count, 0)
        XCTAssertEqual(Set(requestedStoreIDs.ids), [albumID], "every store request is under the album id")
    }

    func testRenamingAHiddenCloudKitAlbumKeepsItsHiddenFlagAndCover() async throws {
        let harness = try makeMetadataHarness(isHidden: true, coverMediaID: "cover-5")
        let albumID = harness.album.albumID!
        let newName = "HiddenRenamed-\(UUID().uuidString)"

        let renamed = try harness.manager.renameAlbum(album: harness.album, to: newName)

        let marker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertTrue(marker.isHidden)
        XCTAssertEqual(marker.coverMediaID, "cover-5")
        XCTAssertTrue(harness.manager.isAlbumHidden(renamed))
        XCTAssertEqual(harness.manager.getAlbumCoverImageId(album: renamed), "cover-5")
        XCTAssertFalse(harness.manager.fetchAlbumsFromSources(includingHidden: false).contains { $0.albumID == albumID })
        let saved = await waitUntil { harness.store.savedAlbumCalls.count == 1 }
        XCTAssertTrue(saved)
        XCTAssertEqual(harness.store.savedAlbumCalls.first?.isHidden, true)
        XCTAssertEqual(harness.store.savedAlbumCalls.first?.coverMediaID, "cover-5")
        try assertNameKeyedSettingsUntouched(harness)
        XCTAssertNil(try harness.syncedStore.fetchAlbum(name: newName), "nothing is written under the new name")
    }

    func testRenamingOntoAHiddenCloudKitAlbumsNameThrowsAlbumExists() async throws {
        let harness = try makeMetadataHarness()
        let hiddenName = "HiddenTaken-\(UUID().uuidString)"
        let hidden = cloudKitAlbum(name: hiddenName, key: harness.album.key)
        try writeMarker(CloudKitAlbumMarker(album: hidden, isHidden: true), albumID: hidden.albumID!)
        let encNameBefore = CloudKitAlbumMarker.read(albumID: harness.album.albumID!)?.encName

        XCTAssertThrowsError(try harness.manager.renameAlbum(album: harness.album, to: hiddenName)) { error in
            XCTAssertEqual(error as? AlbumError, .albumExists)
        }

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: harness.album.albumID!)?.encName, encNameBefore)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: harness.album.albumID!)?.dirty, false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(harness.store.saveAlbumAttemptCount, 0)
    }

    func testRenamingOntoAnAlbumInTheOtherStorageThrowsAlbumExists() throws {
        let harness = try makeMetadataHarness()
        let localName = "LocalTaken-\(UUID().uuidString)"
        let local = try makeLocalAlbum(harness.manager, name: localName)
        harness.manager.setIsAlbumHidden(true, album: local)

        XCTAssertThrowsError(try harness.manager.renameAlbum(album: harness.album, to: localName),
                             "a CloudKit album onto a hidden local album's name") { error in
            XCTAssertEqual(error as? AlbumError, .albumExists)
        }
        XCTAssertThrowsError(try harness.manager.renameAlbum(album: local, to: harness.album.name),
                             "a local album onto a CloudKit album's name") { error in
            XCTAssertEqual(error as? AlbumError, .albumExists)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.storageURL.path), "the local album did not move")
    }

    func testAnOfflineCloudKitRenameStaysDirtyUntilTheNextReconcilePushesIt() async throws {
        let harness = try makeMetadataHarness()
        let album = harness.album
        let albumID = album.albumID!
        harness.store.seedAlbum(CloudKitAlbumMetadata(albumID: albumID,
                                                      encName: album.encryptedPathComponent,
                                                      createdAt: album.creationDate,
                                                      isHidden: false,
                                                      schemaVersion: CloudKitSchema.currentSchemaVersion,
                                                      keyFingerprint: album.key.keychainLabel,
                                                      recordChangeTag: "tag"))
        harness.store.saveAlbumError = CloudKitMediaStoreError.retry(after: 1)
        let newName = "Offline-\(UUID().uuidString)"

        let renamed = try harness.manager.renameAlbum(album: album, to: newName)

        let attempted = await waitUntil { harness.store.saveAlbumAttemptCount == 1 }
        XCTAssertTrue(attempted)
        try await Task.sleep(nanoseconds: 100_000_000)
        let offlineMarker = try XCTUnwrap(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertTrue(offlineMarker.dirty, "the rename waits for the reconciler")
        XCTAssertEqual(offlineMarker.encName, renamed.encryptedPathComponent, "the rename still applies on this device")
        XCTAssertEqual(harness.manager.fetchAlbumsFromSources(includingHidden: true)
            .first { $0.albumID == albumID }?.name, newName)

        harness.store.saveAlbumError = nil
        let reconciler = CloudKitAlbumReconciler(store: harness.store,
                                                 keyManager: harness.manager.keyManager,
                                                 albumManager: harness.manager,
                                                 deleteQueue: CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults()),
                                                 publishRegistry: CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults()))
        _ = await reconciler.reconcileAlbums()

        let pushed = harness.store.savedAlbumCalls.filter { $0.albumID == albumID }
        XCTAssertEqual(pushed.map(\.encName), [renamed.encryptedPathComponent], "the reconciler saves the new name")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.dirty, false)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.encName, renamed.encryptedPathComponent)
    }
}
