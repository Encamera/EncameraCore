//
//  AlbumSizeSidecarTests.swift
//  EncameraCoreTests
//
//  The per-album size sidecar and the sync paths that fill it, driven through the
//  `CloudKitMediaStoring` fake — never a live container.
//

import XCTest
@testable import EncameraCore

final class AlbumSizeSidecarTests: XCTestCase {

    private var tempRoot: URL!
    private var deleteQueueSuites: [String] = []

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        iCloudStorageModel.testContainerRootOverride = nil
        ICloudPlaceholderName.testEvictedURLs = nil
        try? FileManager.default.removeItem(at: tempRoot)
        for suite in deleteQueueSuites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        deleteQueueSuites = []
    }

    // MARK: - Builders

    private func sidecarURL() -> URL {
        tempRoot.appendingPathComponent("\(UUID().uuidString).encsizes")
    }

    private func makeDeleteQueue() -> CloudKitMediaDeleteQueue {
        let suite = "sidecar-delete-\(UUID().uuidString)"
        deleteQueueSuites.append(suite)
        return CloudKitMediaDeleteQueue(suiteName: suite)
    }

    private func makeCoordinator(store: MockCloudKitMediaStore,
                                 sidecar: AlbumSizeSidecar) -> CloudKitSyncCoordinator {
        let index = MediaIndexStore(keyBytes: Array(repeating: 7, count: 32),
                                    indexURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encindex"))
        let cache = CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-\(UUID().uuidString)"),
                                      maxBytes: 500 * 1024 * 1024)
        return CloudKitSyncCoordinator.forTesting(albumID: "a1",
                                       store: store,
                                       cache: cache,
                                       indexStore: index,
                                       sizeSidecar: sidecar,
                                       bus: FileOperationBus(),
                                       deleteQueue: makeDeleteQueue())
    }

    private func meta(recordName: String,
                      mediaID: String,
                      type: MediaType,
                      sizeBytes: Int64) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: recordName,
                              albumID: "a1",
                              mediaID: mediaID,
                              mediaType: type,
                              createdAt: Date(timeIntervalSince1970: 100),
                              sizeBytes: sizeBytes,
                              creationDeviceID: "device",
                              schemaVersion: 1,
                              recordChangeTag: "tag-\(recordName)")
    }

    // MARK: - Tests

    /// The headline correctness test: a Live Photo is two CloudKit records that
    /// collapse into one index entry, and both components' bytes must survive that
    /// collapse. Keying by `mediaID` would report only one of these sizes.
    func testSizesByRecordNameReturnsTheWholeMap() async throws {
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        try await sidecar.replace(with: ["a#0": 10, "a#1": 20])
        try await sidecar.apply(updates: ["b#1": 5], removals: ["a#1"], owner: .cloudKit, entries: [])

        let sizes = await sidecar.sizesByRecordName()
        let total = await sidecar.totalBytes()

        XCTAssertEqual(sizes, ["a#0": 10, "b#1": 5])
        XCTAssertEqual(sizes.values.reduce(0, +), total)
    }

    func testLivePhotoComponentsBothCountTowardTotal() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [
                meta(recordName: "live#0", mediaID: "live", type: .photo, sizeBytes: 700),
                meta(recordName: "live#1", mediaID: "live", type: .video, sizeBytes: 3_300),
            ],
            deleted: [], token: nil, moreComing: false
        )
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)

        try await coord.sync()

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 4_000, "Both Live Photo components must contribute their own size")
        let count = await sidecar.recordCount()
        XCTAssertEqual(count, 2, "Sizes are keyed by record name, so two records mean two keys")
    }

    func testDeltaSyncPersistsSizesFromMetadata() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [
                meta(recordName: "m1#0", mediaID: "m1", type: .photo, sizeBytes: 111),
                meta(recordName: "m2#0", mediaID: "m2", type: .photo, sizeBytes: 222),
            ],
            deleted: [], token: nil, moreComing: false
        )
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)

        try await coord.sync()

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 333)
    }

    func testRemovedRecordStopsCountingTowardTotal() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [
                meta(recordName: "live#0", mediaID: "live", type: .photo, sizeBytes: 700),
                meta(recordName: "live#1", mediaID: "live", type: .video, sizeBytes: 3_300),
            ],
            deleted: [], token: nil, moreComing: false
        )
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)
        try await coord.sync()

        try await coord.remove(recordName: "live#1", albumID: "a1")
        var total = await sidecar.totalBytes()
        XCTAssertEqual(total, 700, "Removing the video component drops only the video's bytes")

        try await coord.remove(recordName: "live#0", albumID: "a1")
        total = await sidecar.totalBytes()
        XCTAssertEqual(total, 0)
    }

    func testUploadRecordsItsSizeInTheSidecar() async throws {
        let store = MockCloudKitMediaStore()
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let coord = makeCoordinator(store: store, sidecar: sidecar)
        let blob = tempRoot.appendingPathComponent("m1.blob")
        try Data(repeating: 9, count: 64).write(to: blob)

        let upload = CloudKitMediaUpload(albumID: "a1", mediaID: "m1", mediaType: .photo,
                                         createdAt: Date(timeIntervalSince1970: 555), sizeBytes: 1_234,
                                         encryptedFileURL: blob, encryptedThumbURL: nil,
                                         recordName: "m1#0")
        _ = try await coord.upload(upload, progress: { _ in })

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 1_234)
    }

    func testSidecarSurvivesRelaunch() async throws {
        let url = sidecarURL()
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: "m1#0", mediaID: "m1", type: .photo, sizeBytes: 4_096)],
            deleted: [], token: nil, moreComing: false
        )
        let coord = makeCoordinator(store: store, sidecar: AlbumSizeSidecar(fileURL: url))
        try await coord.sync()

        let relaunched = AlbumSizeSidecar(fileURL: url)
        let total = await relaunched.totalBytes()
        XCTAssertEqual(total, 4_096)
        let existed = await relaunched.existsOnDisk()
        XCTAssertTrue(existed)
    }

    /// The sidecar answers a Settings screen. Failing to write it must never fail a
    /// sync or hold back the change-token commit.
    func testSidecarWriteFailureDoesNotFailSync() async throws {
        let store = MockCloudKitMediaStore()
        store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: "m1#0", mediaID: "m1", type: .photo, sizeBytes: 10)],
            deleted: [], token: nil, moreComing: false
        )
        let blocker = tempRoot.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let sidecar = AlbumSizeSidecar(fileURL: blocker.appendingPathComponent("a.encsizes"))
        let coord = makeCoordinator(store: store, sidecar: sidecar)

        try await coord.sync()

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 0, "Nothing persisted, but the sync itself succeeded")
        XCTAssertEqual(store.committedTokenCount, 1, "The change token still commits after a sidecar failure")
    }

    /// The privacy guard: the file is named by a hash and holds record names and
    /// integers only.
    func testSidecarContainsNoCleartextAlbumName() async throws {
        let key = PrivateKey(keyBytes: Array(repeating: 3, count: 32), creationDate: Date())
        let album = Album(name: "Beach Trip 2026", storageOption: .cloudKit, creationDate: Date(), key: key,
                          albumID: UUID().uuidString)
        let url = AlbumSizeSidecar.sidecarURL(for: album)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let sidecar = AlbumSizeSidecar(album: album)
        try await sidecar.replace(with: ["m1#0": 42])

        XCTAssertFalse(url.lastPathComponent.contains("Beach"),
                       "The filename is a hash of the album id, not its name")
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "Beach Trip"),
                     "No cleartext album name may reach the sidecar")
    }

    func testApplyMergesRatherThanReplacingUnseenRecords() async throws {
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        try await sidecar.apply(updates: ["m1#0": 100, "m2#0": 200], removals: [], owner: .cloudKit, entries: [])
        try await sidecar.apply(updates: ["m2#0": 250], removals: [], owner: .cloudKit, entries: [])

        let total = await sidecar.totalBytes()
        XCTAssertEqual(total, 350, "A delta that mentions one record must not zero the others")
    }

    // MARK: - Ownership by component location

    /// File sizes as iCloud Drive metadata reports them, keyed by materialized
    /// filename, for evicted files too. Nothing here can download a file.
    private final class MetadataSizes: ICloudDriveSizing, @unchecked Sendable {
        var sizes: [String: Int64] = [:]
        private(set) var calls = 0
        var isReachable: Bool { true }
        func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]? {
            calls += 1
            return sizes
        }
    }

    /// A CloudKit album "a1" with its own index and sidecar, a coordinator over
    /// them, and its linked iCloud Drive folder holding a marker naming it.
    private struct LinkedAlbum {
        let album: Album
        let folder: URL
        let index: MediaIndexStore
        let sidecar: AlbumSizeSidecar
        let store: MockCloudKitMediaStore
        let coordinator: CloudKitSyncCoordinator
        let albumManager: MockAlbumManager
        let sizing: MetadataSizes

        func scanner() -> ICloudDriveFolderScanner {
            let folder = folder
            return ICloudDriveFolderScanner(album: album, indexStore: index, sizeSidecar: sidecar, sizing: sizing,
                                            store: store, bus: FileOperationBus(),
                                            isICloudDriveAvailable: { true },
                                            linkedFolder: { $0 == "a1" ? folder : nil })
        }

        func url(_ id: String, _ type: MediaType) -> URL {
            folder.appendingPathComponent("\(id).\(type.encryptedFileExtension)")
        }

        /// Writes a downloaded file whose metadata reports `metadataBytes`.
        func addFile(_ id: String, _ type: MediaType, metadataBytes: Int64) throws {
            try Data(repeating: 1, count: 64).write(to: url(id, type))
            sizing.sizes[url(id, type).lastPathComponent] = metadataBytes
        }

        /// Leaves only the iCloud placeholder of a file whose metadata reports
        /// `metadataBytes`.
        func addEvictedFile(_ id: String, _ type: MediaType, metadataBytes: Int64) throws {
            try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: url(id, type)))
            sizing.sizes[url(id, type).lastPathComponent] = metadataBytes
        }

        func entries() async -> [MediaIndexEntry] {
            await index.current()?.entries ?? []
        }

        func mediaBytes() async -> AlbumMediaBytes {
            await albumManager.mediaBytes(for: album)
        }
    }

    private func makeLinkedAlbum() throws -> LinkedAlbum {
        iCloudStorageModel.testContainerRootOverride = tempRoot.appendingPathComponent("container", isDirectory: true)
        let driveAlbum = Album(name: "drive-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(),
                               key: MockAlbumManager.testAlbumKey)
        let model = iCloudStorageModel(album: driveAlbum)
        try model.initializeDirectories()
        try ICloudDriveAlbumMarkerFile(albumID: "a1").write(toAlbumDirectory: model.baseURL)

        let index = MediaIndexStore(keyBytes: MockAlbumManager.testAlbumKey.keyBytes,
                                    indexURL: tempRoot.appendingPathComponent("\(UUID().uuidString).encindex"))
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let store = MockCloudKitMediaStore()
        let cache = CloudKitBlobCache(baseDir: tempRoot.appendingPathComponent("cache-\(UUID().uuidString)"),
                                      maxBytes: 500 * 1024 * 1024)
        let (coordinator, albumManager) = CloudKitSyncCoordinator.forTesting(
            albums: [("a1", index, sidecar)], store: store, cache: cache,
            bus: FileOperationBus(), deleteQueue: makeDeleteQueue())
        let album = try XCTUnwrap(albumManager.cloudKitAlbum(withID: "a1"))
        return LinkedAlbum(album: album, folder: model.baseURL, index: index, sidecar: sidecar, store: store,
                           coordinator: coordinator, albumManager: albumManager, sizing: MetadataSizes())
    }

    private func photo(_ id: String) -> String { MediaRecordName.componentRecordName(mediaID: id, type: .photo) }
    private func video(_ id: String) -> String { MediaRecordName.componentRecordName(mediaID: id, type: .video) }

    func testICloudDriveSizesComeFromMetadataWithoutDownload() async throws {
        let a = try makeLinkedAlbum()
        try a.addFile("downloaded", .photo, metadataBytes: 5_000)
        try a.addEvictedFile("evicted", .photo, metadataBytes: 7_000)
        try a.addFile("live", .photo, metadataBytes: 1_000)
        try a.addEvictedFile("live", .video, metadataBytes: 9_000)

        let result = await a.scanner().scan()

        guard case .scanned(let added, _) = result else { return XCTFail("expected a scan, got \(result)") }
        XCTAssertEqual(added.count, 4)
        let sizes = await a.sidecar.sizesByRecordName()
        XCTAssertEqual(sizes, [photo("downloaded"): 5_000, photo("evicted"): 7_000,
                               photo("live"): 1_000, video("live"): 9_000],
                       "every size is the metadata's, not the 64 bytes on disk, and an evicted file reports its size")
        XCTAssertFalse(ICloudPlaceholderName.isMaterialized(a.url("evicted", .photo)),
                       "sizing an evicted file does not download it")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ICloudPlaceholderName.placeholderURL(forMaterialized: a.url("evicted", .photo)).path))
        let bytes = await a.mediaBytes()
        XCTAssertEqual(bytes, AlbumMediaBytes(remainingOnICloudDrive: 22_000, total: 22_000))
    }

    func testSyncDoesNotRemoveICloudDriveSizes() async throws {
        let a = try makeLinkedAlbum()
        try a.addFile("onDrive", .photo, metadataBytes: 4_000)
        await a.scanner().scan()

        a.store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: photo("cloud"), mediaID: "cloud", type: .photo, sizeBytes: 300)],
            deleted: [photo("onDrive")], token: nil, moreComing: false, snapshotComplete: true)
        try await a.coordinator.sync()

        var sizes = await a.sidecar.sizesByRecordName()
        XCTAssertEqual(sizes, [photo("onDrive"): 4_000, photo("cloud"): 300],
                       "neither a feed delete nor a full-walk reap removes an iCloud Drive size")

        // A record that exists before the feed delivers it: its fetched size is
        // not written over the size of the component the index still places on
        // iCloud Drive.
        a.store.metadataToReturn = [meta(recordName: photo("onDrive"), mediaID: "onDrive", type: .photo,
                                         sizeBytes: 4_100)]
        _ = await a.coordinator.remoteBytes(recordName: photo("onDrive"), albumID: "a1")

        sizes = await a.sidecar.sizesByRecordName()
        XCTAssertEqual(sizes[photo("onDrive")], 4_000)
        let bytes = await a.mediaBytes()
        XCTAssertEqual(bytes, AlbumMediaBytes(remainingOnICloudDrive: 4_000, total: 4_300))
    }

    func testFlipMovesSizeWithoutDoubleCounting() async throws {
        let a = try makeLinkedAlbum()
        try a.addFile("plain", .photo, metadataBytes: 2_000)
        try a.addFile("live", .photo, metadataBytes: 500)
        try a.addEvictedFile("live", .video, metadataBytes: 6_000)
        await a.scanner().scan()
        var bytes = await a.mediaBytes()
        XCTAssertEqual(bytes, AlbumMediaBytes(remainingOnICloudDrive: 8_500, total: 8_500))

        // Mid-move: the plain photo and the Live Photo's photo half land in CloudKit.
        a.store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: photo("plain"), mediaID: "plain", type: .photo, sizeBytes: 2_048),
                      meta(recordName: photo("live"), mediaID: "live", type: .photo, sizeBytes: 520)],
            deleted: [], token: nil, moreComing: false)
        try await a.coordinator.sync()

        let entries = await a.entries()
        XCTAssertEqual(entries.first { $0.id == "plain" }?.photoLocation, .cloudKit, "precondition: the feed flipped it")
        bytes = await a.mediaBytes()
        XCTAssertEqual(bytes, AlbumMediaBytes(remainingOnICloudDrive: 6_000, total: 8_568),
                       "a moved component counts once, at its CloudKit size")
        var count = await a.sidecar.recordCount()
        XCTAssertEqual(count, 3, "one size per component, whichever side holds it")

        // The files are still in the folder until the move deletes them; a rescan
        // must not put their iCloud Drive sizes back.
        await a.scanner().scan()
        bytes = await a.mediaBytes()
        XCTAssertEqual(bytes, AlbumMediaBytes(remainingOnICloudDrive: 6_000, total: 8_568))
        let sizes = await a.sidecar.sizesByRecordName()
        XCTAssertEqual(sizes, [photo("plain"): 2_048, photo("live"): 520, video("live"): 6_000])

        // After the move: the last half lands and the folder empties.
        a.store.changeSet = CloudKitChangeSet(
            changed: [meta(recordName: video("live"), mediaID: "live", type: .video, sizeBytes: 6_016)],
            deleted: [], token: nil, moreComing: false)
        try await a.coordinator.sync()
        for (id, type) in [("plain", MediaType.photo), ("live", .photo)] {
            try FileManager.default.removeItem(at: a.url(id, type))
        }
        try FileManager.default.removeItem(at: ICloudPlaceholderName.placeholderURL(forMaterialized: a.url("live", .video)))
        a.sizing.sizes = [:]
        await a.scanner().scan()

        bytes = await a.mediaBytes()
        XCTAssertEqual(bytes, AlbumMediaBytes(remainingOnICloudDrive: 0, total: 8_584))
        count = await a.sidecar.recordCount()
        XCTAssertEqual(count, 3)
        let total = await a.sidecar.totalBytes()
        XCTAssertEqual(total, 8_584)
    }

    func testBytesRemainingCountsOnlyICloudDriveComponents() async throws {
        let sidecar = AlbumSizeSidecar(fileURL: sidecarURL())
        let date = Date(timeIntervalSince1970: 100)
        let entries = [
            MediaIndexEntry(id: "drive", hasPhotoComponent: true, hasVideoComponent: false, dateEncrypted: date,
                            dateTaken: date, subtypeRawValue: 0, photoLocation: .iCloudDrive, videoLocation: .iCloudDrive),
            MediaIndexEntry(id: "cloud", hasPhotoComponent: true, hasVideoComponent: false, dateEncrypted: date,
                            dateTaken: date, subtypeRawValue: 0, photoLocation: .cloudKit, videoLocation: .cloudKit),
            MediaIndexEntry(id: "half", hasPhotoComponent: true, hasVideoComponent: true, dateEncrypted: date,
                            dateTaken: date, subtypeRawValue: 0, photoLocation: .cloudKit, videoLocation: .iCloudDrive),
            MediaIndexEntry(id: "unsized", hasPhotoComponent: true, hasVideoComponent: false, dateEncrypted: date,
                            dateTaken: date, subtypeRawValue: 0, photoLocation: .iCloudDrive, videoLocation: .iCloudDrive)
        ]
        try await sidecar.replace(with: [photo("drive"): 100, photo("cloud"): 20, photo("half"): 3,
                                      video("half"): 4_000, photo("gone"): 50_000])

        let bytes = await sidecar.mediaBytes(for: entries)

        XCTAssertEqual(bytes.remainingOnICloudDrive, 4_100, "the iCloud Drive photo and the Live Photo's video half")
        XCTAssertEqual(bytes.total, 4_123, "every indexed component once; a size the index no longer holds is not counted")
        let empty = await sidecar.mediaBytes(for: [])
        XCTAssertEqual(empty, AlbumMediaBytes(remainingOnICloudDrive: 0, total: 0))
    }
}
