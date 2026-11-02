//
//  ICloudDriveAlbumFolderWalkTests.swift
//  EncameraCoreTests
//
//  The walk over this device's iCloud Drive album folders: how each folder is
//  classified by its marker file, which CloudKit album it adopts and links, and
//  what the album list shows while that happens.
//
//  The iCloud Drive container is a scratch directory (`testContainerRootOverride`)
//  and the album list is the real `AlbumManager`. Only the CloudKit store is a
//  fake.
//

import XCTest
import Combine
@testable import EncameraCore

@MainActor
final class ICloudDriveAlbumFolderWalkTests: XCTestCase {

    private var containerRoot: URL!
    private var key: PrivateKey!
    private var albumManager: AlbumManager!
    private var store: MockCloudKitMediaStore!
    private var publishRegistry: CloudKitAlbumPublishRegistry!
    private var deleteQueue: CloudKitAlbumDeleteQueue!
    private var requestedDownloads: DownloadRequests!
    private var conflicts: MarkerConflicts!
    private var extraContainerRoots: [URL] = []
    private var adoptedAlbumIDs: [String] = []
    private var cancellables = Set<AnyCancellable>()

    private final class DownloadRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func append(_ url: URL) { lock.withLock { _urls.append(url) } }
    }

    /// The fake `NSFileVersion` store: the conflict versions of each marker file,
    /// as files outside the folder, and the markers each resolution kept.
    private final class MarkerConflicts: @unchecked Sendable {
        private let lock = NSLock()
        private var _versions: [String: [URL]] = [:]
        private var _kept: [ICloudDriveAlbumMarkerFile] = []
        private let directory: URL

        init(directory: URL) { self.directory = directory }

        /// An empty upload queue of the walking device's own.
        var uploadQueueDirectory: URL { directory.appendingPathComponent("upload-queue", isDirectory: true) }

        var kept: [ICloudDriveAlbumMarkerFile] { lock.withLock { _kept } }

        private static func key(_ markerURL: URL) -> String {
            markerURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        }

        func add(_ marker: ICloudDriveAlbumMarkerFile, toMarkerIn folder: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("version-\(UUID().uuidString).json")
            try marker.encoded().write(to: url)
            let key = Self.key(ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder))
            lock.withLock { _versions[key, default: []].append(url) }
        }

        func versions(of markerURL: URL) -> [URL] {
            lock.withLock { _versions[Self.key(markerURL)] ?? [] }
        }

        /// Resolves through the real file write, then drops the fake versions as
        /// `NSFileVersion.removeOtherVersionsOfItem` would.
        func resolve(_ markerURL: URL, keeping marker: ICloudDriveAlbumMarkerFile) throws {
            try ICloudDriveAlbumMarkerFile.resolveConflict(at: markerURL, keeping: marker)
            lock.withLock {
                _versions[Self.key(markerURL)] = nil
                _kept.append(marker)
            }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("folder-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: iCloudStorageModelAlbumsURL, withIntermediateDirectories: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot

        key = PrivateKey(keyBytes: (0..<32).map { _ in UInt8.random(in: 0...255) }, creationDate: Date())
        let keyManager = DemoKeyManager(keys: [key])
        keyManager.currentKey = key
        albumManager = AlbumManager(keyManager: keyManager, syncedDataStore: nil)
        store = MockCloudKitMediaStore()
        publishRegistry = CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults())
        deleteQueue = CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults())
        requestedDownloads = DownloadRequests()
        conflicts = MarkerConflicts(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("marker-versions-\(UUID().uuidString)", isDirectory: true))
    }

    override func tearDownWithError() throws {
        for albumID in adoptedAlbumIDs {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        iCloudStorageModel.testContainerRootOverride = nil
        for root in extraContainerRoots + [containerRoot].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: root)
        }
        cancellables.removeAll()
        albumManager = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private var iCloudStorageModelAlbumsURL: URL {
        containerRoot.appendingPathComponent(AlbumDirectoryNaming.albumsDirectory, isDirectory: true)
    }

    private struct Folder {
        let url: URL
        let name: String
    }

    /// An iCloud Drive album folder holding one media file. A ciphertext folder is
    /// named with the album name encrypted under the key, in the `albums/` layout;
    /// a legacy one is named with the plaintext name, at the root as pre-encryption
    /// builds left it.
    private func makeFolder(ciphertextName: Bool) throws -> Folder {
        let name = "trip-\(UUID().uuidString)"
        let url: URL
        if ciphertextName {
            let directoryName = Album(name: name, storageOption: .icloud, creationDate: Date(), key: key)
                .encryptedPathComponent
            url = iCloudStorageModelAlbumsURL.appendingPathComponent(directoryName, isDirectory: true)
        } else {
            url = containerRoot.appendingPathComponent(name, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("ciphertext-\(UUID().uuidString)".utf8)
            .write(to: url.appendingPathComponent("\(UUID().uuidString).encimage"))
        return Folder(url: url, name: name)
    }

    @discardableResult
    private func writeMarker(in folder: Folder, albumID: String = UUID().uuidString) throws -> String {
        try ICloudDriveAlbumMarkerFile(albumID: albumID).write(toAlbumDirectory: folder.url)
        return albumID
    }

    /// The `EncAlbum` the migrating device saved for `folder`'s album.
    private func record(albumID: String, name: String,
                        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CloudKitAlbumMetadata {
        let encName = Album(name: name, storageOption: .cloudKit, creationDate: Date(), key: key, albumID: albumID)
            .encryptedPathComponent
        adoptedAlbumIDs.append(albumID)
        return CloudKitAlbumMetadata(albumID: albumID, encName: encName,
                                     createdAt: createdAt,
                                     isHidden: false, schemaVersion: 1,
                                     keyFingerprint: key.keyFingerprint, recordChangeTag: "tag")
    }

    private func makeWalk() -> ICloudDriveAlbumFolderWalk {
        let store = self.store!
        let requests = self.requestedDownloads!
        let conflicts = self.conflicts!
        return ICloudDriveAlbumFolderWalk(albumManager: albumManager,
                                          makeStore: { store },
                                          publishRegistry: publishRegistry,
                                          deleteQueue: deleteQueue,
                                          requestMarkerDownload: { requests.append($0) },
                                          conflictVersions: { conflicts.versions(of: $0) },
                                          resolveMarkerConflict: { try conflicts.resolve($0, keeping: $1) },
                                          uploadQueue: CloudKitUploadQueue(baseDir: conflicts.uploadQueueDirectory))
    }

    private func walk(_ folder: Folder) async -> ICloudDriveAlbumFolderWalk.FolderResult? {
        await makeWalk().run().first { $0.folder.standardizedFileURL == folder.url.standardizedFileURL }
    }

    /// Every file under `folder`, hidden ones included, with its bytes.
    private func snapshot(_ folder: Folder) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder.url, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }

    private enum Listed: Equatable { case folder, cloudKitAlbum, both, neither }

    /// What `albums` shows for the album: its iCloud Drive folder, its CloudKit
    /// album, both or neither.
    private func listed(_ albums: [Album], folder: Folder, albumID: String) -> Listed {
        let showsFolder = albums.contains { $0.storageOption == .icloud && $0.name == folder.url.lastPathComponent.decryptedName(key: key) }
        let showsCloudKit = albums.contains { $0.storageOption == .cloudKit && $0.albumID == albumID }
        switch (showsFolder, showsCloudKit) {
        case (true, true): return .both
        case (true, false): return .folder
        case (false, true): return .cloudKitAlbum
        case (false, false): return .neither
        }
    }

    private func listed(folder: Folder, albumID: String) -> Listed {
        listed(albumManager.fetchAlbumsFromSources(includingHidden: true), folder: folder, albumID: albumID)
    }

    private var fetchByIDCount: Int {
        store.callOrder.filter { if case .fetchAlbum = $0 { return true } else { return false } }.count
    }

    // MARK: - Case 1

    func testNoMarkerListsAsPlainICloudDriveAlbum() async throws {
        XCTAssertEqual(ICloudDriveAlbumAdoptionState.classify(marker: .absent, isAdopted: { _ in true }), .noMarker)
        XCTAssertTrue(ICloudDriveAlbumAdoptionState.noMarker.listsFolderAsPlainAlbum)

        let folder = try makeFolder(ciphertextName: true)
        // A listed CloudKit album, so the list does read folder markers.
        let other = record(albumID: UUID().uuidString, name: "other")
        albumManager.adoptCloudKitAlbum(record: other, key: key)
        let before = try snapshot(folder)

        let result = await walk(folder)

        XCTAssertEqual(result?.adoptionState, .noMarker)
        XCTAssertEqual(result?.changedAlbumMarker, false)
        XCTAssertEqual(fetchByIDCount, 0)
        XCTAssertTrue(albumManager.fetchAlbumsFromSources(includingHidden: true)
            .contains { $0.storageOption == .icloud && $0.name == folder.name })
        XCTAssertEqual(try snapshot(folder), before)
    }

    // MARK: - Case 2

    func testAdoptedMarkerIsNotListedSeparately() async throws {
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        XCTAssertEqual(ICloudDriveAlbumAdoptionState.classify(marker: .present(.init(albumID: albumID)),
                                                              isAdopted: { $0 == albumID }),
                       .adopted(albumID: albumID))
        XCTAssertFalse(ICloudDriveAlbumAdoptionState.adopted(albumID: albumID).listsFolderAsPlainAlbum)

        // Adopted by the reconciler from the album query, with no link yet.
        albumManager.adoptCloudKitAlbum(record: record(albumID: albumID, name: folder.name), key: key)
        XCTAssertNil(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID))
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .cloudKitAlbum)
        let before = try snapshot(folder)

        let result = await walk(folder)

        XCTAssertEqual(result?.adoptionState, .adopted(albumID: albumID))
        XCTAssertEqual(result?.changedAlbumMarker, true)
        XCTAssertEqual(fetchByIDCount, 0, "an adopted album is never fetched")
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       folder.url.standardizedFileURL)
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.dirty, false, "the link is not a record change")
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .cloudKitAlbum)
        XCTAssertEqual(try snapshot(folder), before)

        let again = await walk(folder)
        XCTAssertEqual(again?.changedAlbumMarker, false, "an unchanged link is not rewritten")
    }

    /// The walk is deliberately not held for Wi-Fi: on a second device album sync
    /// adopts the album on its own, and only the walk links it to the folder that
    /// still holds its unmoved items. Gating the walk would hide those items
    /// until Wi-Fi returned.
    func testWalkOffWiFiStillAdoptsMarkedFolder() async throws {
        NetworkMonitor.shared.force(.cellular)
        defer { NetworkMonitor.shared.force(nil) }
        XCTAssertFalse(NetworkMonitor.shared.isOnUnmeteredNetwork, "precondition: off Wi-Fi")
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        albumManager.adoptCloudKitAlbum(record: record(albumID: albumID, name: folder.name), key: key)
        XCTAssertNil(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID))

        let result = await walk(folder)

        XCTAssertEqual(result?.adoptionState, .adopted(albumID: albumID))
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       folder.url.standardizedFileURL,
                       "off Wi-Fi the walk still links the adopted album to its folder")
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .cloudKitAlbum, "listed once")
    }

    // MARK: - Case 3

    func testSecondDeviceAdoptsAlbumIDAndLinksFolder_ciphertextFolderName() async throws {
        try await assertSecondDeviceAdoptsAndLinks(ciphertextName: true)
    }

    func testSecondDeviceAdoptsAlbumIDAndLinksFolder_legacyPlaintextFolderName() async throws {
        try await assertSecondDeviceAdoptsAndLinks(ciphertextName: false)
    }

    private func assertSecondDeviceAdoptsAndLinks(ciphertextName: Bool) async throws {
        let folder = try makeFolder(ciphertextName: ciphertextName)
        let albumID = try writeMarker(in: folder)
        store.seedAlbum(record(albumID: albumID, name: folder.name))
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .folder)
        let before = try snapshot(folder)

        let result = await walk(folder)

        guard case .adoptable(let adopted) = result?.adoptionState else {
            return XCTFail("expected the record to be adopted, got \(String(describing: result?.adoptionState))")
        }
        XCTAssertEqual(adopted.albumID, albumID)
        XCTAssertEqual(result?.changedAlbumMarker, true)
        XCTAssertEqual(fetchByIDCount, 1)
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       folder.url.standardizedFileURL)
        XCTAssertTrue(publishRegistry.isPublished(albumID))

        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        XCTAssertEqual(listed(albums, folder: folder, albumID: albumID), .cloudKitAlbum)
        XCTAssertEqual(albums.first { $0.albumID == albumID }?.name, folder.name)
        XCTAssertEqual(try snapshot(folder), before)

        let again = await walk(folder)
        XCTAssertEqual(again?.adoptionState, .adopted(albumID: albumID))
        XCTAssertEqual(fetchByIDCount, 1, "once adopted, the walk reads the marker but fetches nothing")
    }

    func testAlbumListSwitchesInOneStepDuringAdoption() async throws {
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        store.seedAlbum(record(albumID: albumID, name: folder.name))
        let gate = AsyncGate()
        store.fetchAlbumGate = gate

        var broadcasts: [Listed] = []
        albumManager.albumOperationPublisher
            .sink { [unowned self] operation in
                guard case .albumsUpdated(let albums) = operation else { return }
                broadcasts.append(self.listed(albums, folder: folder, albumID: albumID))
            }
            .store(in: &cancellables)

        XCTAssertEqual(listed(folder: folder, albumID: albumID), .folder, "before the fetch")

        let walk = makeWalk()
        let run = Task { await walk.run() }
        await gate.waitUntilEntered()
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .folder, "while the fetch is in flight")
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID))

        await gate.release()
        _ = await run.value

        XCTAssertEqual(listed(folder: folder, albumID: albumID), .cloudKitAlbum, "after adoption")
        XCTAssertFalse(broadcasts.isEmpty)
        XCTAssertTrue(broadcasts.allSatisfy { $0 == .folder || $0 == .cloudKitAlbum },
                      "every broadcast list shows exactly one of the two: \(broadcasts)")
        XCTAssertEqual(broadcasts.last, .cloudKitAlbum)
    }

    // MARK: - Case 4

    func testEvictedMarkerNeverDeletesAndListsAsPlain() async throws {
        XCTAssertEqual(ICloudDriveAlbumAdoptionState.classify(marker: .evicted, isAdopted: { _ in true }),
                       .markerEvicted)

        let folder = try makeFolder(ciphertextName: true)
        let albumID = UUID().uuidString
        // Adopted here, but only the marker's placeholder is on the device, so the
        // folder cannot be tied to the album yet.
        albumManager.adoptCloudKitAlbum(record: record(albumID: albumID, name: folder.name), key: key)
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder.url)
        try Data("placeholder".utf8).write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: markerURL))
        let before = try snapshot(folder)

        let result = await walk(folder)

        XCTAssertEqual(result?.adoptionState, .markerEvicted)
        let resolved: (URL) -> URL = {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent)
        }
        XCTAssertEqual(requestedDownloads.urls.map(resolved), [resolved(markerURL)])
        XCTAssertEqual(fetchByIDCount, 0)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID)?.iCloudDriveFolderPath)
        XCTAssertTrue(albumManager.fetchAlbumsFromSources(includingHidden: true)
            .contains { $0.storageOption == .icloud && $0.name == folder.name })
        XCTAssertEqual(try snapshot(folder), before)
        XCTAssertFalse(store.callOrder.contains { if case .deleteAlbum = $0 { return true } else { return false } })
    }

    // MARK: - Case 5

    func testMarkerNamingGoneRecordNeverDeletes() async throws {
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        publishRegistry.markConfirmedOnServer(albumID)
        let before = try snapshot(folder)

        let result = await walk(folder)

        XCTAssertEqual(result?.adoptionState, .recordGone(albumID: albumID))
        XCTAssertEqual(fetchByIDCount, 1)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .folder)
        XCTAssertEqual(try snapshot(folder), before)
        XCTAssertTrue(ICloudDriveAlbumAdoptionState.recordGone(albumID: albumID).listsFolderAsPlainAlbum)
        XCTAssertTrue(store.callOrder.allSatisfy { call in
            switch call {
            case .fetchAlbum: return true
            default: return false
            }
        }, "the walk only reads from CloudKit: \(store.callOrder)")
    }

    // MARK: - Case 6

    func testMarkerNamingUnpublishedRecordWaits() async throws {
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        let before = try snapshot(folder)

        let first = await walk(folder)

        XCTAssertEqual(first?.adoptionState, .recordNotVisibleYet(albumID: albumID))
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: albumID))
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .folder)
        XCTAssertEqual(try snapshot(folder), before)

        // The record reaches the server; the next walk adopts it.
        store.seedAlbum(record(albumID: albumID, name: folder.name))
        let second = await walk(folder)

        guard case .adoptable = second?.adoptionState else {
            return XCTFail("expected adoption on the next walk, got \(String(describing: second?.adoptionState))")
        }
        XCTAssertEqual(fetchByIDCount, 2)
        XCTAssertEqual(listed(folder: folder, albumID: albumID), .cloudKitAlbum)
        XCTAssertEqual(try snapshot(folder), before)
    }

    // MARK: - Case 7: conflicting marker versions

    /// Two `EncAlbum`s saved for one folder, as two devices migrating it in one
    /// sync window leave it: `current` is this device's marker version, `conflict`
    /// the other device's, and both records are on the server.
    private struct Conflict {
        let folder: Folder
        let earlier: CloudKitAlbumMetadata
        let later: CloudKitAlbumMetadata
    }

    private func makeConflict(earlierID: String = UUID().uuidString,
                              laterID: String = UUID().uuidString,
                              earlierCreatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                              laterCreatedAt: Date = Date(timeIntervalSince1970: 1_700_000_500),
                              currentIsEarlier: Bool = false,
                              in store: MockCloudKitMediaStore? = nil) throws -> Conflict {
        let folder = try makeFolder(ciphertextName: true)
        let earlier = record(albumID: earlierID, name: folder.name, createdAt: earlierCreatedAt)
        let later = record(albumID: laterID, name: folder.name, createdAt: laterCreatedAt)
        let (current, other) = currentIsEarlier ? (earlier, later) : (later, earlier)
        try writeMarker(in: folder, albumID: current.albumID)
        try conflicts.add(ICloudDriveAlbumMarkerFile(albumID: other.albumID), toMarkerIn: folder.url)
        (store ?? self.store).seedAlbum(earlier)
        (store ?? self.store).seedAlbum(later)
        return Conflict(folder: folder, earlier: earlier, later: later)
    }

    private func markerOnDisk(_ folder: Folder) -> ICloudDriveAlbumMarkerFile.ReadResult {
        ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder.url, conflictVersions: { [conflicts] in conflicts!.versions(of: $0) })
    }

    /// Every file in the folder but the marker, which resolution rewrites.
    private func mediaSnapshot(_ folder: Folder) throws -> [String: Data] {
        try snapshot(folder).filter { !ICloudDriveAlbumMarkerFile.isMarkerFileName($0.key) }
    }

    private var deletedAlbumIDs: [String] {
        store.callOrder.compactMap { if case .deleteAlbum(let id) = $0 { return id } else { return nil } }
    }

    func testConflictingMarkersResolveToEarliestEncAlbum() async throws {
        let conflict = try makeConflict()
        XCTAssertEqual(markerOnDisk(conflict.folder),
                       .conflicted([.init(albumID: conflict.later.albumID), .init(albumID: conflict.earlier.albumID)]))
        XCTAssertEqual(listed(folder: conflict.folder, albumID: conflict.earlier.albumID), .folder)
        let media = try mediaSnapshot(conflict.folder)

        let result = await walk(conflict.folder)

        XCTAssertEqual(result?.adoptionState, .adoptable(conflict.earlier))
        XCTAssertEqual(result?.changedAlbumMarker, true)
        XCTAssertEqual(conflicts.kept, [.init(albumID: conflict.earlier.albumID)], "the conflict is resolved once, to the earlier album")
        XCTAssertEqual(markerOnDisk(conflict.folder), .present(.init(albumID: conflict.earlier.albumID)),
                       "the kept version is the marker's current version and no conflict is left")
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: conflict.earlier.albumID)?.standardizedFileURL,
                       conflict.folder.url.standardizedFileURL)
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: conflict.later.albumID), "the losing album is never adopted")
        XCTAssertEqual(listed(folder: conflict.folder, albumID: conflict.earlier.albumID), .cloudKitAlbum)
        XCTAssertEqual(try mediaSnapshot(conflict.folder), media)

        let again = await walk(conflict.folder)
        XCTAssertEqual(again?.adoptionState, .adopted(albumID: conflict.earlier.albumID), "then handled as case 2")
        XCTAssertEqual(conflicts.kept.count, 1)
    }

    func testConflictTieBreakUsesAlbumIDWhenCreatedAtEqual() async throws {
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let smallerID = "00000000-0000-4000-8000-\(UUID().uuidString.suffix(12))"
        let largerID = "FFFFFFFF-0000-4000-8000-\(UUID().uuidString.suffix(12))"
        // The current version names the larger id, so the walk has to switch.
        let conflict = try makeConflict(earlierID: smallerID, laterID: largerID,
                                        earlierCreatedAt: sameDate, laterCreatedAt: sameDate)
        XCTAssertTrue(CloudKitAlbumMetadata.precedes(conflict.earlier, conflict.later))
        XCTAssertFalse(CloudKitAlbumMetadata.precedes(conflict.later, conflict.earlier))

        let result = await walk(conflict.folder)

        XCTAssertEqual(result?.adoptionState.albumID, smallerID)
        XCTAssertEqual(markerOnDisk(conflict.folder), .present(.init(albumID: smallerID)))
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: smallerID))
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: largerID))
    }

    func testConflictResolutionIsSameOnEveryDevice() async throws {
        // The pure choice does not depend on which version a device holds as current.
        let a = record(albumID: UUID().uuidString, name: "a", createdAt: Date(timeIntervalSince1970: 100))
        let b = record(albumID: UUID().uuidString, name: "a", createdAt: Date(timeIntervalSince1970: 100))
        let c = record(albumID: UUID().uuidString, name: "a", createdAt: Date(timeIntervalSince1970: 50))
        for records in [[a, b, c], [c, b, a], [b, c, a]] {
            let lookups = Dictionary(uniqueKeysWithValues: records.map { ($0.albumID, ICloudDriveAlbumRecordLookup.found($0)) })
            guard case .keep(let winner, let losers) = ICloudDriveAlbumAdoptionState.resolveConflict(lookups: lookups,
                                                                                                      isPublished: { _ in false }) else {
                return XCTFail("expected a winner")
            }
            XCTAssertEqual(winner, c)
            XCTAssertEqual(Set(losers.map(\.albumID)), [a.albumID, b.albumID])
        }

        // Device 1 holds the later album's version as current, device 2 the
        // earlier one's. Each has its own iCloud Drive copy, server view and state.
        let earlierID = UUID().uuidString
        let laterID = UUID().uuidString
        let device1 = try makeConflict(earlierID: earlierID, laterID: laterID, currentIsEarlier: false)
        let result1 = await walk(device1.folder)

        try CloudKitAlbumMarker.remove(albumID: earlierID)
        try? CloudKitAlbumMarker.remove(albumID: laterID)
        extraContainerRoots.append(containerRoot)
        containerRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("folder-walk-device2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: iCloudStorageModelAlbumsURL, withIntermediateDirectories: true)
        iCloudStorageModel.testContainerRootOverride = containerRoot
        store = MockCloudKitMediaStore()
        publishRegistry = CloudKitAlbumPublishRegistry(defaults: makeIsolatedDefaults())
        deleteQueue = CloudKitAlbumDeleteQueue(defaults: makeIsolatedDefaults())
        let device2 = try makeConflict(earlierID: earlierID, laterID: laterID, currentIsEarlier: true)
        let result2 = await walk(device2.folder)

        XCTAssertEqual(result1?.adoptionState.albumID, earlierID)
        XCTAssertEqual(result2?.adoptionState.albumID, earlierID)
        XCTAssertEqual(markerOnDisk(device1.folder), .present(.init(albumID: earlierID)))
        XCTAssertEqual(markerOnDisk(device2.folder), .present(.init(albumID: earlierID)))
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: earlierID)?.standardizedFileURL,
                       device2.folder.url.standardizedFileURL)
    }

    func testEmptyLosingEncAlbumIsDeletedAfterFreshFetch() async throws {
        let conflict = try makeConflict()
        // This device migrated the folder into the later album, so it has adopted it.
        albumManager.adoptCloudKitAlbum(record: conflict.later, key: key, linkingICloudDriveFolder: conflict.folder.url)
        publishRegistry.markConfirmedOnServer(conflict.later.albumID)
        XCTAssertNotNil(albumManager.cloudKitAlbum(withID: conflict.later.albumID))
        let media = try mediaSnapshot(conflict.folder)

        let result = await walk(conflict.folder)

        XCTAssertEqual(result?.adoptionState.albumID, conflict.earlier.albumID)
        XCTAssertEqual(deletedAlbumIDs, [conflict.later.albumID])
        let calls = store.callOrder
        guard let deleteIndex = calls.firstIndex(of: .deleteAlbum(albumID: conflict.later.albumID)) else {
            return XCTFail("no delete in \(calls)")
        }
        XCTAssertEqual(calls[deleteIndex - 1], .fetchChanges, "the membership fetch comes right before the delete: \(calls)")
        let lastLookup = calls.lastIndex { if case .fetchAlbum = $0 { return true } else { return false } } ?? -1
        XCTAssertGreaterThan(calls.firstIndex(of: .fetchChanges) ?? -1, lastLookup,
                             "membership is fetched after the conflict is resolved, not reused from before it")
        XCTAssertNil(CloudKitAlbumMarker.read(albumID: conflict.later.albumID), "the loser leaves this device's list")
        XCTAssertNil(albumManager.cloudKitAlbum(withID: conflict.later.albumID))
        XCTAssertFalse(publishRegistry.isPublished(conflict.later.albumID))
        XCTAssertTrue(deleteQueue.pending().isEmpty)
        XCTAssertEqual(listed(folder: conflict.folder, albumID: conflict.earlier.albumID), .cloudKitAlbum)
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflict.folder.url.path))
        XCTAssertEqual(try mediaSnapshot(conflict.folder), media, "no iCloud Drive file is deleted with the album")
    }

    func testLosingEncAlbumWithMediaIsKept() async throws {
        let conflict = try makeConflict()
        albumManager.adoptCloudKitAlbum(record: conflict.later, key: key)
        store.addServerRecord(albumID: conflict.later.albumID)
        let media = try mediaSnapshot(conflict.folder)

        let result = await walk(conflict.folder)

        XCTAssertEqual(result?.adoptionState.albumID, conflict.earlier.albumID, "the folder still goes to the winner")
        XCTAssertEqual(store.fetchChangesCount, 1, "membership was checked")
        XCTAssertEqual(deletedAlbumIDs, [], "an album holding media is left for the user")
        XCTAssertTrue(deleteQueue.pending().isEmpty)
        XCTAssertNotNil(CloudKitAlbumMarker.read(albumID: conflict.later.albumID))
        XCTAssertNotNil(albumManager.cloudKitAlbum(withID: conflict.later.albumID))
        XCTAssertEqual(try mediaSnapshot(conflict.folder), media)

        // A membership check that cannot reach the server deletes nothing either;
        // the delete waits in the queue for the reconciler's own check.
        let second = try makeConflict()
        store.fetchChangesError = CloudKitMediaStoreError.retry(after: 1)
        _ = await walk(second.folder)
        XCTAssertEqual(deletedAlbumIDs, [])
        XCTAssertTrue(deleteQueue.requiresNoMembers(second.later.albumID))
    }

    /// A candidate whose record cannot be fetched, or may still be on its way,
    /// leaves the conflict for a later walk. One confirmed gone drops out.
    func testConflictWithUnfetchableCandidateWaits() async throws {
        let conflict = try makeConflict()
        store.fetchAlbumError = CloudKitMediaStoreError.retry(after: 1)
        let failed = await walk(conflict.folder)
        guard case .markerConflicted = failed?.adoptionState else {
            return XCTFail("expected the conflict to wait, got \(String(describing: failed?.adoptionState))")
        }
        XCTAssertTrue(conflicts.kept.isEmpty)
        XCTAssertEqual(listed(folder: conflict.folder, albumID: conflict.earlier.albumID), .folder)

        // The earlier record is not on the server and was never seen published.
        store.fetchAlbumError = nil
        let gone = try makeConflict()
        try await store.deleteAlbum(albumID: gone.earlier.albumID)
        let waiting = await walk(gone.folder)
        guard case .markerConflicted = waiting?.adoptionState else {
            return XCTFail("expected the conflict to wait, got \(String(describing: waiting?.adoptionState))")
        }

        // Once seen published, its absence means it was deleted: the other wins.
        publishRegistry.markConfirmedOnServer(gone.earlier.albumID)
        let resolved = await walk(gone.folder)
        XCTAssertEqual(resolved?.adoptionState.albumID, gone.later.albumID)
        XCTAssertEqual(markerOnDisk(gone.folder), .present(.init(albumID: gone.later.albumID)))
        XCTAssertEqual(deletedAlbumIDs.filter { $0 == gone.earlier.albumID }.count, 1,
                       "only the test's own setup deleted the gone record")
        XCTAssertFalse(deletedAlbumIDs.contains(gone.later.albumID))
    }

    func testResolveConflictWritesKeptVersionInPlace() throws {
        let folder = try makeFolder(ciphertextName: true)
        try writeMarker(in: folder, albumID: "current")
        let markerURL = ICloudDriveAlbumMarkerFile.url(inAlbumDirectory: folder.url)
        let inode = try FileManager.default.attributesOfItem(atPath: markerURL.path)[.systemFileNumber] as? Int

        try ICloudDriveAlbumMarkerFile.resolveConflict(at: markerURL, keeping: .init(albumID: "kept"))

        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder.url), .present(.init(albumID: "kept")))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: markerURL.path)[.systemFileNumber] as? Int, inode,
                       "rewritten in place, so its versions stay with it")
    }

    // MARK: - Case 8: a folder renamed by an older build

    func testFolderRenamedByOldBuildIsReLinkedThroughMarker() async throws {
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        albumManager.adoptCloudKitAlbum(record: record(albumID: albumID, name: folder.name), key: key,
                                        linkingICloudDriveFolder: folder.url)
        let before = try snapshot(folder)

        // An older build renames the folder; the marker moves with it.
        let renamed = Folder(url: folder.url.deletingLastPathComponent()
                                .appendingPathComponent("renamed-\(UUID().uuidString)", isDirectory: true),
                             name: folder.name)
        try FileManager.default.moveItem(at: folder.url, to: renamed.url)

        let result = await walk(renamed)

        XCTAssertEqual(result?.adoptionState, .adopted(albumID: albumID))
        XCTAssertEqual(result?.changedAlbumMarker, true)
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       renamed.url.standardizedFileURL)
        XCTAssertEqual(try snapshot(renamed), before, "nothing in the folder is renamed or deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path), "the walk does not recreate the old name")

        // A folder that still holds the album's marker keeps its link when a second
        // folder names the album too.
        let copy = try makeFolder(ciphertextName: true)
        try writeMarker(in: copy, albumID: albumID)
        _ = await makeWalk().run()
        XCTAssertEqual(CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID)?.standardizedFileURL,
                       renamed.url.standardizedFileURL)

        // With no folder naming the album, the stale link is left as it is.
        let linkedPath = CloudKitAlbumMarker.read(albumID: albumID)?.iCloudDriveFolderPath
        try FileManager.default.removeItem(at: copy.url)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        extraContainerRoots.append(outside)
        try FileManager.default.moveItem(at: renamed.url, to: outside)
        _ = await makeWalk().run()
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.iCloudDriveFolderPath, linkedPath)
    }

    func testRenameOnThisBuildNeverTouchesFolder() async throws {
        let folder = try makeFolder(ciphertextName: true)
        let albumID = try writeMarker(in: folder)
        store.seedAlbum(record(albumID: albumID, name: folder.name))
        _ = await walk(folder)
        guard let album = albumManager.cloudKitAlbum(withID: albumID) else { return XCTFail("not adopted") }
        let linkedPath = CloudKitAlbumMarker.read(albumID: albumID)?.iCloudDriveFolderPath
        let before = try snapshot(folder)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.url.deletingLastPathComponent().path)
        let priorMakeStore = CloudKitStoreProvider.makeStore
        let store = self.store!
        CloudKitStoreProvider.makeStore = { _ in store }
        defer { CloudKitStoreProvider.makeStore = priorMakeStore }

        let renamed = try albumManager.renameAlbum(album: album, to: "renamed-\(UUID().uuidString)")

        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.encName, renamed.encryptedPathComponent,
                       "the rename lands in album.json")
        XCTAssertEqual(CloudKitAlbumMarker.read(albumID: albumID)?.iCloudDriveFolderPath, linkedPath)
        XCTAssertEqual(try snapshot(folder), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.url.deletingLastPathComponent().path), siblings,
                       "no folder is renamed or created")
        XCTAssertEqual(ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder.url), .present(.init(albumID: albumID)))

        let again = await walk(folder)
        XCTAssertEqual(again?.adoptionState, .adopted(albumID: albumID))
        XCTAssertEqual(again?.changedAlbumMarker, false)
    }

    // MARK: - The folder link

    /// `album.json` written before the link existed has no `iCloudDriveFolderPath`
    /// key and reads as an unlinked album.
    func testMarkerWithoutFolderLinkDecodesAsUnlinked() throws {
        let json = #"{"encName":"Album_x","createdAt":0,"isHidden":false,"dirty":false}"#
        let marker = try JSONDecoder().decode(CloudKitAlbumMarker.self, from: Data(json.utf8))
        XCTAssertNil(marker.iCloudDriveFolderPath)
        XCTAssertNil(marker.linkedICloudDriveFolderURL())
    }
}

private extension String {
    /// The album name a folder name stands for: decrypted when it is ciphertext,
    /// itself when it is a legacy plaintext name.
    func decryptedName(key: PrivateKey) -> String {
        Album.decryptedAlbumName(self, key: key) ?? self
    }
}
