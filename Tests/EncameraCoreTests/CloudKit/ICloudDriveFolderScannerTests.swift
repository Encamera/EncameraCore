//
//  ICloudDriveFolderScannerTests.swift
//  EncameraCoreTests
//
//  The folder scanner owns the `.iCloudDrive` half of a CloudKit album's index.
//  These run against a real folder under a substituted ubiquity container root,
//  real encrypted files and a real index store; only iCloud's placeholder state
//  (`FakeICloudDriveMaterializer.evictForTest`), the record check
//  (`MockCloudKitMediaStore`) and the folder's change notifications are faked.
//

import XCTest
import Combine
@testable import EncameraCore

@MainActor
final class ICloudDriveFolderScannerTests: XCTestCase {

    private var containerRoot: URL?
    private var indexDirectory: URL?
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
        if let indexDirectory { try? FileManager.default.removeItem(at: indexDirectory) }
        iCloudStorageModel.testContainerRootOverride = nil
        iCloudStorageModel.containerSource = .fileManager
        ICloudPlaceholderName.testEvictedURLs = nil
        containerRoot = nil
        indexDirectory = nil
        cancellables.removeAll()
        try? MediaIndexStore.clearAllIndexes()
        super.tearDown()
    }

    // MARK: - Fixture

    private final class FakeFolderChangeSource: ICloudDriveFolderChangeSource {
        private(set) var startedFolders: [URL] = []
        private(set) var stopCount = 0
        private var onChange: (@Sendable () -> Void)?

        nonisolated init() {}

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

    private struct NoSizes: ICloudDriveSizing {
        var isReachable: Bool { false }
        func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]? { nil }
    }

    private struct Fixture {
        let driveAlbum: Album
        let cloudKitAlbum: Album
        let folder: URL
        let indexURL: URL
        let indexStore: MediaIndexStore
        let sizeSidecar: AlbumSizeSidecar
        let store: MockCloudKitMediaStore
        let bus: FileOperationBus
        let changeSource: FakeFolderChangeSource
        let albumManager: MockAlbumManager
        let materializer: FakeICloudDriveMaterializer

        var albumID: String { cloudKitAlbum.albumID! }

        func scanner(store: CloudKitMediaStoring?? = .none) -> ICloudDriveFolderScanner {
            let folder = folder
            let albumID = albumID
            let resolvedStore: CloudKitMediaStoring? = store ?? self.store
            return ICloudDriveFolderScanner(album: cloudKitAlbum, indexStore: indexStore,
                                            sizeSidecar: sizeSidecar, sizing: NoSizes(), store: resolvedStore,
                                            bus: bus, changeSource: changeSource,
                                            isICloudDriveAvailable: { true },
                                            linkedFolder: { $0 == albumID ? folder : nil })
        }

        func photoURL(_ id: String) -> URL {
            folder.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        }

        func videoURL(_ id: String) -> URL {
            folder.appendingPathComponent("\(id).\(MediaType.video.encryptedFileExtension)")
        }

        /// Saves a real encrypted photo into the folder, as an older build would.
        func addPhoto(captureDate: Date? = nil) async throws -> String {
            let id = UUID().uuidString
            var metadata: EncryptedFileMetadata?
            if let captureDate {
                var withDate = EncryptedFileMetadata()
                withDate.captureDate = captureDate
                metadata = withDate
            }
            let backend = DiskMediaBackend()
            await backend.configure(for: driveAlbum, albumManager: albumManager)
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
                ]),
                metadata: metadata, progress: { _ in })
            return id
        }

        /// Writes opaque bytes under a video component's name. The scanner reads
        /// only names and headers, so a video needs no real content.
        func addVideoFile(id: String) throws {
            try Data((0..<64).map { _ in UInt8.random(in: 0...255) }).write(to: videoURL(id))
        }

        func entries() async -> [MediaIndexEntry] {
            await indexStore.current()?.entries ?? []
        }

        func entry(_ id: String) async -> MediaIndexEntry? {
            await entries().first { $0.id == id }
        }
    }

    private func makeFixture(albumCreationDate: Date = Date(timeIntervalSince1970: 1_600_000_000)) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("folder-scanner-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = root
        containerRoot = root

        let key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let driveAlbum = Album(name: "drive-\(UUID().uuidString)", storageOption: .icloud,
                               creationDate: albumCreationDate, key: key)
        let albumID = UUID().uuidString
        let cloudKitAlbum = Album(name: "ck-\(UUID().uuidString)", storageOption: .cloudKit,
                                  creationDate: albumCreationDate, key: key, albumID: albumID)

        let model = iCloudStorageModel(album: driveAlbum)
        try model.initializeDirectories()
        let folder = model.baseURL
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: folder)

        let indexDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("folder-scanner-index-\(UUID().uuidString)", isDirectory: true)
        indexDirectory = indexDir
        let indexURL = indexDir.appendingPathComponent("album.encindex")

        let keyManager = DemoKeyManager()
        keyManager.currentKey = key
        return Fixture(driveAlbum: driveAlbum, cloudKitAlbum: cloudKitAlbum, folder: folder,
                       indexURL: indexURL,
                       indexStore: MediaIndexStore(keyBytes: key.keyBytes, indexURL: indexURL),
                       sizeSidecar: AlbumSizeSidecar(fileURL: indexDir.appendingPathComponent("album.encsizes")),
                       store: MockCloudKitMediaStore(), bus: FileOperationBus(),
                       changeSource: FakeFolderChangeSource(),
                       albumManager: MockAlbumManager(keyManager: keyManager),
                       materializer: FakeICloudDriveMaterializer())
    }

    private func photo(_ id: String) -> String { MediaRecordName.componentRecordName(mediaID: id, type: .photo) }
    private func video(_ id: String) -> String { MediaRecordName.componentRecordName(mediaID: id, type: .video) }

    // MARK: - Full scan

    /// Also the wiped-index case: the sync rebuild restores only the CloudKit
    /// entries, and one scan restores every file the index lost.
    func testScanAddsEntryForEveryFileWithoutCloudKitEntry() async throws {
        let f = try makeFixture()
        let plain = [try await f.addPhoto(), try await f.addPhoto()]
        let livePhoto = try await f.addPhoto()
        try f.addVideoFile(id: livePhoto)
        let halfMigrated = try await f.addPhoto()
        try f.addVideoFile(id: halfMigrated)
        let migratedNotYetDeleted = try await f.addPhoto()
        let cloudKitOnly = UUID().uuidString
        try Data("notes".utf8).write(to: f.folder.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: f.folder.appendingPathComponent("a.b.\(MediaType.photo.encryptedFileExtension)"))

        let recordDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cloudKitHalf = [
            MediaIndexEntry(id: halfMigrated, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: recordDate, dateTaken: recordDate, subtypeRawValue: 0),
            MediaIndexEntry(id: migratedNotYetDeleted, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: recordDate, dateTaken: recordDate, subtypeRawValue: 0),
            MediaIndexEntry(id: cloudKitOnly, hasPhotoComponent: true, hasVideoComponent: false,
                            dateEncrypted: recordDate, dateTaken: recordDate, subtypeRawValue: 0)
        ]
        try await f.indexStore.replace(with: cloudKitHalf)

        let result = await f.scanner().scan()

        XCTAssertEqual(result, .scanned(added: [photo(plain[0]), photo(plain[1]), photo(livePhoto),
                                                video(livePhoto), video(halfMigrated)].sorted(),
                                        removed: []))
        let entries = await f.entries()
        XCTAssertEqual(entries.count, 6, "four folder items, two of them sharing an entry with a CloudKit half, plus the CloudKit-only entry")
        for id in plain {
            let entry = await f.entry(id)
            XCTAssertEqual(entry?.hasPhotoComponent, true)
            XCTAssertEqual(entry?.photoLocation, .iCloudDrive)
        }
        let liveEntry = await f.entry(livePhoto)
        let live = try XCTUnwrap(liveEntry)
        XCTAssertTrue(live.hasPhotoComponent && live.hasVideoComponent, "a Live Photo's two files are one entry")
        XCTAssertEqual(live.photoLocation, .iCloudDrive)
        XCTAssertEqual(live.videoLocation, .iCloudDrive)
        let halfEntry = await f.entry(halfMigrated)
        let half = try XCTUnwrap(halfEntry)
        XCTAssertEqual(half.photoLocation, .cloudKit, "the half with a record stays CloudKit's")
        XCTAssertEqual(half.videoLocation, .iCloudDrive, "only the half without one is added")
        XCTAssertEqual(half.dateTaken, recordDate, "adding a half keeps the entry's date")
        let migrated = await f.entry(migratedNotYetDeleted)
        XCTAssertEqual(migrated, cloudKitHalf[1], "a file whose component is already in CloudKit is left alone")
        let cloudKit = await f.entry(cloudKitOnly)
        XCTAssertEqual(cloudKit, cloudKitHalf[2], "a CloudKit component with no file is CloudKit's to manage")

        let rescan = await f.scanner().scan()
        XCTAssertEqual(rescan, .scanned(added: [], removed: []), "a second scan finds nothing to change")

        try FileManager.default.removeItem(at: f.indexURL)
        let rebuilt = await f.scanner().scan()
        guard case .scanned(let added, _) = rebuilt else { return XCTFail("expected a scan, got \(rebuilt)") }
        XCTAssertEqual(added.count, 7, "a wiped index gets every component in the folder back from one scan")
    }

    func testScanIgnoresMarkerFile() async throws {
        let f = try makeFixture()
        let id = try await f.addPhoto()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: f.folder).path), "precondition: the marker is in the folder")

        let result = await f.scanner().scan()

        XCTAssertEqual(result, .scanned(added: [photo(id)], removed: []))
        let ids = await f.entries().map(\.id)
        XCTAssertEqual(ids, [id])
    }

    func testFolderWhoseMarkerDoesNotNameThisAlbumIsNotScanned() async throws {
        let f = try makeFixture()
        _ = try await f.addPhoto()
        let otherAlbumID = UUID().uuidString
        try ICloudDriveAlbumMarkerFile(albumID: otherAlbumID).write(toAlbumDirectory: f.folder)

        let mismatched = await f.scanner().scan()
        XCTAssertEqual(mismatched, .skipped(.markerNamesAnotherAlbum(albumID: otherAlbumID)))

        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: f.folder)
        try FileManager.default.removeItem(at: markerURL)
        let absent = await f.scanner().scan()
        XCTAssertEqual(absent, .skipped(.markerAbsent))

        try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL))
        let evicted = await f.scanner().scan()
        XCTAssertEqual(evicted, .skipped(.markerEvicted))

        let entries = await f.entries()
        XCTAssertTrue(entries.isEmpty, "nothing is indexed from a folder not proven to be this album's")
    }

    // MARK: - Dates

    func testEntryDateMatchesMigrationCreatedAt() async throws {
        let f = try makeFixture(albumCreationDate: Date(timeIntervalSince1970: 1_500_000_000))
        let captured = try await f.addPhoto(captureDate: Date(timeIntervalSince1970: 1_550_000_000))
        let encryptedOnly = try await f.addPhoto()
        let evictedInPlace = try await f.addPhoto()
        let evictedToBrick = try await f.addPhoto()
        try f.materializer.evictForTest(f.photoURL(evictedInPlace), shape: .pathPersists)
        try f.materializer.evictForTest(f.photoURL(evictedToBrick), shape: .replacedByPlaceholderBrick)

        let manager = CloudKitMigrationManager(albumManager: f.albumManager,
                                               storeFactory: { _ in f.store },
                                               materializer: f.materializer)
        let plan = try await manager.plan(album: f.driveAlbum)
        let createdAt = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.mediaID, $0.createdAt) })
        XCTAssertEqual(Set(createdAt.keys), [captured, encryptedOnly, evictedInPlace, evictedToBrick],
                       "precondition: migration planned every file")
        XCTAssertEqual(createdAt[captured], Date(timeIntervalSince1970: 1_550_000_000),
                       "precondition: the capture date is migration's createdAt")

        await f.scanner().scan()

        for id in [captured, encryptedOnly, evictedInPlace, evictedToBrick] {
            let entryEntry = await f.entry(id)
            let entry = try XCTUnwrap(entryEntry, "every file is indexed, evicted ones included")
            XCTAssertEqual(entry.dateTaken, createdAt[id], "the entry sorts where its record will")
            XCTAssertEqual(entry.dateEncrypted, createdAt[id], "the entry sorts where its record will")
        }
    }

    // MARK: - Removal

    func testEvictedFileIsNotRemoved() async throws {
        let f = try makeFixture()
        let inPlace = try await f.addPhoto()
        let brick = try await f.addPhoto()
        await f.scanner().scan()

        try f.materializer.evictForTest(f.photoURL(inPlace), shape: .pathPersists)
        try f.materializer.evictForTest(f.photoURL(brick), shape: .replacedByPlaceholderBrick)
        let result = await f.scanner().scan()

        XCTAssertEqual(result, .scanned(added: [], removed: []))
        let ids = Set(await f.entries().map(\.id))
        XCTAssertEqual(ids, [inPlace, brick], "an evicted file is still the album's media")
    }

    func testNotYetSyncedFileIsNotRemoved() async throws {
        let f = try makeFixture()
        let downloading = UUID().uuidString
        try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: f.photoURL(downloading)))
        let uploadedElsewhere = try await f.addPhoto()
        let unreachable = try await f.addPhoto()
        await f.scanner().scan()
        let indexed = Set(await f.entries().map(\.id))
        XCTAssertEqual(indexed, [downloading, uploadedElsewhere, unreachable],
                       "a file only iCloud's placeholder stands for yet is indexed")

        for id in [uploadedElsewhere, unreachable] {
            try FileManager.default.removeItem(at: f.photoURL(id))
        }

        let withoutStore = await f.scanner(store: .some(nil)).scan()
        XCTAssertEqual(withoutStore, .scanned(added: [], removed: []),
                       "without a store, nothing can confirm no record exists")

        f.store.confirmAlbumOverride[photo(uploadedElsewhere)] = .success(f.albumID)
        f.store.confirmAlbumOverride[photo(unreachable)] = .failure(CloudKitMediaStoreError.retry(after: 3))
        let result = await f.scanner().scan()
        XCTAssertEqual(result, .scanned(added: [], removed: []),
                       "a record that exists, or a check that fails, keeps the component")

        let ids = Set(await f.entries().map(\.id))
        XCTAssertEqual(ids, [downloading, uploadedElsewhere, unreachable])
    }

    func testConfirmedGoneFileWithNoRecordIsRemoved() async throws {
        let f = try makeFixture()
        let gone = try await f.addPhoto()
        let livePhoto = try await f.addPhoto()
        try f.addVideoFile(id: livePhoto)
        let kept = try await f.addPhoto()
        await f.scanner().scan()

        var events: [FileOperation] = []
        f.bus.operations.sink { events.append($0) }.store(in: &cancellables)

        try FileManager.default.removeItem(at: f.photoURL(gone))
        try FileManager.default.removeItem(at: f.videoURL(livePhoto))
        let result = await f.scanner().scan()

        XCTAssertEqual(result, .scanned(added: [], removed: [photo(gone), video(livePhoto)].sorted()))
        let ids = Set(await f.entries().map(\.id))
        XCTAssertEqual(ids, [livePhoto, kept])
        let liveEntry = await f.entry(livePhoto)
        let live = try XCTUnwrap(liveEntry)
        XCTAssertTrue(live.hasPhotoComponent && !live.hasVideoComponent, "only the gone half is removed")

        let deleted = events.compactMap { if case .delete(let media) = $0 { return media.map(\.id) } else { return nil } }
        XCTAssertEqual(deleted, [[gone]], "the removed item is posted so the grid drops it")
        let created = events.compactMap { if case .create(let media) = $0 { return media.id } else { return nil } }
        XCTAssertEqual(created, [livePhoto], "the Live Photo that lost a half is posted for a refresh")
    }

    // MARK: - Watch

    func testNewFilePostsBusChange() async throws {
        let f = try makeFixture()
        let scanner = f.scanner()
        let started = await scanner.startWatching()
        XCTAssertTrue(started)
        XCTAssertEqual(f.changeSource.startedFolders, [f.folder], "the watch is on the linked folder")

        let id = UUID().uuidString
        let posted = expectation(description: "the new file is posted on the bus")
        f.bus.operations.sink { operation in
            if case .create(let media) = operation, media.id == id { posted.fulfill() }
        }.store(in: &cancellables)

        try Data("ciphertext from an older build".utf8).write(to: f.photoURL(id))
        f.changeSource.fire()
        await fulfillment(of: [posted], timeout: 5)

        let entry = await f.entry(id)
        XCTAssertEqual(entry?.photoLocation, .iCloudDrive, "the grid's index has the file without a CloudKit sync")

        await scanner.stopWatching()
        XCTAssertEqual(f.changeSource.stopCount, 1)
        let restarted = await scanner.startWatching()
        XCTAssertFalse(restarted, "a stopped watch stays stopped")
        XCTAssertEqual(f.changeSource.startedFolders.count, 1)
    }

    // MARK: - Availability

    func testScannerDoesNotRunWithoutICloudDrive() async throws {
        let f = try makeFixture()
        _ = try await f.addPhoto()
        iCloudStorageModel.testContainerRootOverride = nil
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { false }, containerURL: { nil })
        let albumID = f.albumID
        let folder = f.folder
        let scanner = ICloudDriveFolderScanner(album: f.cloudKitAlbum, indexStore: f.indexStore,
                                               sizeSidecar: f.sizeSidecar, sizing: NoSizes(), store: f.store,
                                               bus: f.bus, changeSource: f.changeSource,
                                               linkedFolder: { $0 == albumID ? folder : nil })

        let result = await scanner.scan()
        let started = await scanner.startWatching()

        XCTAssertEqual(result, .skipped(.iCloudDriveUnavailable))
        XCTAssertFalse(started)
        XCTAssertTrue(f.changeSource.startedFolders.isEmpty, "no watch starts without iCloud Drive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.indexURL.path), "the index is never written")
    }
}
