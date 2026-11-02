//
//  ICloudDriveParitySweepTests.swift
//  EncameraCoreTests
//
//  The parity sweep indexes a CloudKit album's iCloud Drive folder, then passes
//  every file whose component is in CloudKit to the verified delete, and nothing
//  else. These run against a real folder under a substituted ubiquity container
//  root, real encrypted files and a real index store. The verified delete is a
//  spy, which either removes the file as a successful delete would or forwards
//  to the real `ICloudDriveVerifiedDelete` over `MockCloudKitMediaStore`.
//

import XCTest
@testable import EncameraCore

@MainActor
final class ICloudDriveParitySweepTests: XCTestCase {

    private var containerRoot: URL?
    private var indexDirectory: URL?

    override func tearDown() {
        if let containerRoot { try? FileManager.default.removeItem(at: containerRoot) }
        if let indexDirectory { try? FileManager.default.removeItem(at: indexDirectory) }
        iCloudStorageModel.testContainerRootOverride = nil
        containerRoot = nil
        indexDirectory = nil
        try? MediaIndexStore.clearAllIndexes()
        super.tearDown()
    }

    // MARK: - Fixture

    /// Records every component passed to it. By default it removes the file as a
    /// successful verified delete would; `forwardTo` hands the call to a real one,
    /// and `results` answers chosen components without touching their files.
    private final class VerifiedDeleteSpy: ICloudDriveComponentDeleting, @unchecked Sendable {
        struct Call: Equatable {
            let recordName: String
            let albumID: String
            let folder: URL
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _results: [String: ICloudDriveVerifiedDeleteResult] = [:]
        private let forwardTo: ICloudDriveVerifiedDelete?

        init(forwardTo: ICloudDriveVerifiedDelete? = nil) {
            self.forwardTo = forwardTo
        }

        var calls: [Call] { lock.withLock { _calls } }
        var recordNames: [String] { calls.map(\.recordName) }

        func answer(_ recordName: String, with result: ICloudDriveVerifiedDeleteResult?) {
            lock.withLock { _results[recordName] = result }
        }

        func reset() { lock.withLock { _calls = [] } }

        func delete(recordName: String, albumID: String, folder: URL) async -> ICloudDriveVerifiedDeleteResult {
            let result = lock.withLock { () -> ICloudDriveVerifiedDeleteResult? in
                _calls.append(Call(recordName: recordName, albumID: albumID, folder: folder))
                return _results[recordName]
            }
            if let result { return result }
            if let forwardTo { return await forwardTo.delete(recordName: recordName, albumID: albumID, folder: folder) }
            let parsed = MediaRecordName.parse(recordName)
            guard let type = parsed.type else { return .skipped(.invalidRecordName) }
            let url = folder.appendingPathComponent("\(parsed.id).\(type.encryptedFileExtension)")
            do {
                try FileManager.default.removeItem(at: url)
                return .deleted
            } catch {
                return .failed(error)
            }
        }
    }

    private struct NoSizes: ICloudDriveSizing {
        var isReachable: Bool { false }
        func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]? { nil }
    }

    private struct Fixture {
        let driveAlbum: Album
        let cloudKitAlbum: Album
        let folder: URL
        let indexStore: MediaIndexStore
        let sizeSidecar: AlbumSizeSidecar
        let store: MockCloudKitMediaStore
        let albumManager: MockAlbumManager

        var albumID: String { cloudKitAlbum.albumID! }

        func sweep(_ verifiedDelete: ICloudDriveComponentDeleting) -> ICloudDriveParitySweep {
            let folder = folder
            let albumID = albumID
            let scanner = ICloudDriveFolderScanner(album: cloudKitAlbum, indexStore: indexStore,
                                                   sizeSidecar: sizeSidecar, sizing: NoSizes(), store: store,
                                                   bus: FileOperationBus(),
                                                   isICloudDriveAvailable: { true },
                                                   linkedFolder: { $0 == albumID ? folder : nil },
                                                   markerConflictVersions: { _ in [] })
            return ICloudDriveParitySweep(scanner: scanner, indexStore: indexStore, verifiedDelete: verifiedDelete)
        }

        func run(_ verifiedDelete: ICloudDriveComponentDeleting) async -> ICloudDriveParitySweep.Report {
            await sweep(verifiedDelete).run(albumID: albumID, folder: folder)
        }

        func photoURL(_ id: String) -> URL {
            folder.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        }

        func videoURL(_ id: String) -> URL {
            folder.appendingPathComponent("\(id).\(MediaType.video.encryptedFileExtension)")
        }

        /// Saves a real encrypted photo into the folder, as an older build would.
        func addPhoto() async throws -> String {
            let id = UUID().uuidString
            let backend = DiskMediaBackend()
            await backend.configure(for: driveAlbum, albumManager: albumManager)
            _ = try await backend.save(
                media: try InteractableMedia(underlyingMedia: [
                    CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
                ]),
                metadata: nil, progress: { _ in })
            return id
        }

        /// Writes opaque bytes under a video component's name.
        func addVideoFile(id: String) throws {
            try Data((0..<64).map { _ in UInt8.random(in: 0...255) }).write(to: videoURL(id))
        }

        /// The index entry the CloudKit sync writes once the component's record
        /// is in the album: the component at `.cloudKit`.
        func indexInCloudKit(_ id: String, photo: Bool = true, video: Bool = false) async throws {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try await indexStore.upsert([MediaIndexEntry(id: id, hasPhotoComponent: photo, hasVideoComponent: video,
                                                         dateEncrypted: date, dateTaken: date, subtypeRawValue: 0)])
        }

        func entry(_ id: String) async -> MediaIndexEntry? {
            await indexStore.reloadFromDisk()?.entries.first { $0.id == id }
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("parity-sweep-\(UUID().uuidString)", isDirectory: true)
        iCloudStorageModel.testContainerRootOverride = root
        containerRoot = root

        let creationDate = Date(timeIntervalSince1970: 1_600_000_000)
        let key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let driveAlbum = Album(name: "drive-\(UUID().uuidString)", storageOption: .icloud,
                               creationDate: creationDate, key: key)
        let albumID = UUID().uuidString
        let cloudKitAlbum = Album(name: "ck-\(UUID().uuidString)", storageOption: .cloudKit,
                                  creationDate: creationDate, key: key, albumID: albumID)

        let model = iCloudStorageModel(album: driveAlbum)
        try model.initializeDirectories()
        let folder = model.baseURL
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: folder)

        let indexDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("parity-sweep-index-\(UUID().uuidString)", isDirectory: true)
        indexDirectory = indexDir

        let keyManager = DemoKeyManager()
        keyManager.currentKey = key
        return Fixture(driveAlbum: driveAlbum, cloudKitAlbum: cloudKitAlbum, folder: folder,
                       indexStore: MediaIndexStore(keyBytes: key.keyBytes,
                                                   indexURL: indexDir.appendingPathComponent("album.encindex")),
                       sizeSidecar: AlbumSizeSidecar(fileURL: indexDir.appendingPathComponent("album.encsizes")),
                       store: MockCloudKitMediaStore(),
                       albumManager: MockAlbumManager(keyManager: keyManager))
    }

    private func photo(_ id: String) -> String { MediaRecordName.componentRecordName(mediaID: id, type: .photo) }
    private func video(_ id: String) -> String { MediaRecordName.componentRecordName(mediaID: id, type: .video) }

    private func exists(_ url: URL) -> Bool { ICloudPlaceholderName.existsInAnyForm(url) }

    // MARK: - Sweep selection

    /// A killed blob loop and a failed delete both leave the file next to a
    /// component the sync already placed in CloudKit; both halves of a Live Photo
    /// are passed on their own.
    func testSweepCallsVerifiedDeleteForEveryComponentInCloudKit() async throws {
        let f = try makeFixture()
        let uploaded = [try await f.addPhoto(), try await f.addPhoto()]
        let livePhoto = try await f.addPhoto()
        try f.addVideoFile(id: livePhoto)
        for id in uploaded { try await f.indexInCloudKit(id) }
        try await f.indexInCloudKit(livePhoto, photo: true, video: true)
        let spy = VerifiedDeleteSpy()

        let report = await f.run(spy)

        let expected = [photo(uploaded[0]), photo(uploaded[1]), photo(livePhoto), video(livePhoto)].sorted()
        XCTAssertEqual(spy.recordNames.sorted(), expected)
        XCTAssertTrue(spy.calls.allSatisfy { $0.albumID == f.albumID && $0.folder == f.folder })
        XCTAssertEqual(report.swept, expected)
        XCTAssertEqual(report.deleted, expected)
        for id in uploaded + [livePhoto] { XCTAssertFalse(exists(f.photoURL(id))) }
        XCTAssertFalse(exists(f.videoURL(livePhoto)))
    }

    /// Files with no record yet (indexed as `.iCloudDrive`, or not indexed at all
    /// before the scan), a component in CloudKit whose file is already gone, and
    /// the Live Photo half not yet uploaded are never passed.
    func testSweepNeverCallsVerifiedDeleteForComponentNotInCloudKit() async throws {
        let f = try makeFixture()
        let unindexed = try await f.addPhoto()
        let alreadyICloudDrive = try await f.addPhoto()
        let halfUploaded = try await f.addPhoto()
        try f.addVideoFile(id: halfUploaded)
        let cloudKitOnly = UUID().uuidString
        try await f.indexStore.upsert([MediaIndexEntry(id: alreadyICloudDrive, hasPhotoComponent: true,
                                                       hasVideoComponent: false, dateEncrypted: Date(),
                                                       dateTaken: Date(), subtypeRawValue: 0,
                                                       photoLocation: .iCloudDrive)])
        try await f.indexStore.upsert([MediaIndexEntry(id: halfUploaded, hasPhotoComponent: true,
                                                       hasVideoComponent: true, dateEncrypted: Date(),
                                                       dateTaken: Date(), subtypeRawValue: 0,
                                                       photoLocation: .cloudKit, videoLocation: .iCloudDrive)])
        try await f.indexInCloudKit(cloudKitOnly)
        let spy = VerifiedDeleteSpy()

        let report = await f.run(spy)

        XCTAssertEqual(spy.recordNames, [photo(halfUploaded)])
        XCTAssertEqual(report.swept, [photo(halfUploaded)])
        for id in [unindexed, alreadyICloudDrive] { XCTAssertTrue(exists(f.photoURL(id))) }
        XCTAssertTrue(exists(f.videoURL(halfUploaded)))
        let unindexedEntry = await f.entry(unindexed)
        XCTAssertEqual(unindexedEntry?.photoLocation, .iCloudDrive)
    }

    // MARK: - Idempotence

    func testSweepIsNoOpOnSecondRun() async throws {
        let f = try makeFixture()
        let uploaded = try await f.addPhoto()
        let pending = try await f.addPhoto()
        try await f.indexInCloudKit(uploaded)
        let spy = VerifiedDeleteSpy()

        let first = await f.run(spy)
        XCTAssertEqual(first.scan, .scanned(added: [photo(pending)], removed: []))
        XCTAssertEqual(first.deleted, [photo(uploaded)])
        XCTAssertFalse(first.changedNothing)
        let indexAfterFirst = await f.indexStore.reloadFromDisk()?.entries
        spy.reset()

        let second = await f.run(spy)

        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertEqual(second.scan, .scanned(added: [], removed: []))
        XCTAssertEqual(second.swept, [])
        XCTAssertTrue(second.changedNothing)
        let indexAfterSecond = await f.indexStore.reloadFromDisk()?.entries
        XCTAssertEqual(indexAfterSecond, indexAfterFirst)
        XCTAssertTrue(exists(f.photoURL(pending)))
    }

    /// A delete that failed leaves the file; the next pass passes it again and it
    /// goes then.
    func testSweepRetriesFileWhoseDeleteFailed() async throws {
        let f = try makeFixture()
        let uploaded = try await f.addPhoto()
        try await f.indexInCloudKit(uploaded)
        let spy = VerifiedDeleteSpy()
        spy.answer(photo(uploaded), with: .failed(CocoaError(.fileWriteUnknown)))

        let first = await f.run(spy)
        XCTAssertEqual(first.swept, [photo(uploaded)])
        XCTAssertEqual(first.deleted, [])
        XCTAssertTrue(exists(f.photoURL(uploaded)))

        spy.answer(photo(uploaded), with: nil)
        spy.reset()
        let second = await f.run(spy)

        XCTAssertEqual(spy.recordNames, [photo(uploaded)])
        XCTAssertEqual(second.deleted, [photo(uploaded)])
        XCTAssertFalse(exists(f.photoURL(uploaded)))
    }

    // MARK: - Leftovers

    /// Another device uploads a file this device indexed as `.iCloudDrive`; the
    /// sync flips the component to `.cloudKit` and the next pass removes the file
    /// through the real verified delete.
    func testSweepRemovesLeftoverFromAnotherDevicesUpload() async throws {
        let f = try makeFixture()
        let uploadedElsewhere = try await f.addPhoto()
        let stillPending = try await f.addPhoto()
        let spy = VerifiedDeleteSpy(forwardTo: ICloudDriveVerifiedDelete(store: f.store, markerConflictVersions: { _ in [] }))

        let launch = await f.run(spy)
        XCTAssertEqual(launch.scan, .scanned(added: [photo(stillPending), photo(uploadedElsewhere)].sorted(), removed: []))
        XCTAssertTrue(spy.calls.isEmpty)

        let size = try XCTUnwrap(f.photoURL(uploadedElsewhere).fileSizeBytes())
        f.store.metadataToReturn.append(CloudKitMediaMetadata(
            recordName: photo(uploadedElsewhere), albumID: f.albumID, mediaID: uploadedElsewhere, mediaType: .photo,
            createdAt: Date(), sizeBytes: size, creationDeviceID: "other-device", schemaVersion: 1,
            recordChangeTag: "tag"))
        try await f.indexInCloudKit(uploadedElsewhere)
        let flipped = await f.entry(uploadedElsewhere)
        XCTAssertEqual(flipped?.photoLocation, .cloudKit)

        let nextLaunch = await f.run(spy)

        XCTAssertEqual(spy.recordNames, [photo(uploadedElsewhere)])
        XCTAssertEqual(nextLaunch.deleted, [photo(uploadedElsewhere)])
        XCTAssertFalse(exists(f.photoURL(uploadedElsewhere)))
        XCTAssertTrue(exists(f.photoURL(stillPending)))
        let uploadedEntry = await f.entry(uploadedElsewhere)
        let pendingEntry = await f.entry(stillPending)
        XCTAssertEqual(uploadedEntry?.photoLocation, .cloudKit)
        XCTAssertEqual(pendingEntry?.photoLocation, .iCloudDrive)
    }

    // MARK: - Index

    /// An older build adds a file to a folder that is already linked and in
    /// parity; the next pass indexes it as `.iCloudDrive` and passes it nowhere.
    func testIndexBuildAddsFilesAddedByOldBuild() async throws {
        let f = try makeFixture()
        let original = try await f.addPhoto()
        let spy = VerifiedDeleteSpy()
        let first = await f.run(spy)
        XCTAssertEqual(first.scan, .scanned(added: [photo(original)], removed: []))

        let addedByOldBuild = try await f.addPhoto()
        let next = await f.run(spy)

        XCTAssertEqual(next.scan, .scanned(added: [photo(addedByOldBuild)], removed: []))
        let added = await f.entry(addedByOldBuild)
        let entry = try XCTUnwrap(added)
        XCTAssertTrue(entry.hasPhotoComponent)
        XCTAssertEqual(entry.photoLocation, .iCloudDrive)
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertTrue(exists(f.photoURL(addedByOldBuild)))
    }
}
