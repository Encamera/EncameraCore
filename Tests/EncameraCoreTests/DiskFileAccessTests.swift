import XCTest
@testable import EncameraCore

/// Records `keyWith(uuid:)` lookups and `storedKeys()` calls so tests can
/// tell hint-based resolution (xattr, memo) apart from a discovery sweep —
/// `discoverKey` always fetches the stored keys, hint paths never do.
final class SpyKeyManager: DemoKeyManager {
    var keyWithUUIDCalls: [UUID] = []
    var storedKeysCalls = 0

    override func keyWith(uuid: UUID) -> PrivateKey? {
        keyWithUUIDCalls.append(uuid)
        return super.keyWith(uuid: uuid)
    }

    override func storedKeys() throws -> [PrivateKey] {
        storedKeysCalls += 1
        return try super.storedKeys()
    }
}

/// iCloud-shaped storage model backed by a temp directory, so the local-only
/// stamping gate can be tested without a real ubiquity container
/// (`iCloudStorageModel.rootURL` fatalErrors when iCloud is unavailable).
struct FakeICloudStorageModel: DataStorageModel {
    static let rootURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FakeICloudStorageModel", isDirectory: true)

    let album: Album
    var storageType: StorageType { .icloud }
    var baseURL: URL { Self.rootURL.appendingPathComponent(album.encryptedPathComponent, isDirectory: true) }

    init(album: Album) {
        self.album = album
    }
}

final class FakeICloudAlbumManager: DemoAlbumManager {
    override func storageModel(for album: Album) -> DataStorageModel? {
        FakeICloudStorageModel(album: album)
    }
}

final class DiskFileAccessTests: XCTestCase {

    private let keyA = PrivateKey(name: "keyA", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB", keyBytes: Array(repeating: 0x24, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let plaintext = Data((0..<30000).map { UInt8($0 % 251) })

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFileAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeDiskAccess(albumKey: PrivateKey, keyManager: DemoKeyManager) async -> DiskFileAccess {
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: albumKey)
        let albumManager = DemoAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)
        return diskAccess
    }

    private func encryptFixture(with key: PrivateKey, id: String) async throws -> EncryptedMedia {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: id)
        let url = tempDirectory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return EncryptedMedia(source: url, mediaType: .photo, id: id)
    }

    // MARK: - Shared key resolution (stamp-on-open)

    func testDecryptToDataResolvesNonCurrentKey() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext)
    }

    func testDecryptToURLResolvesNonCurrentKey() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let decrypted = try await diskAccess.loadMediaToURL(media: encrypted, progress: { _ in })

        let outputURL = try XCTUnwrap(decrypted.url)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        XCTAssertEqual(try Data(contentsOf: outputURL), plaintext)
    }

    func testDecryptFailsSameAsBeforeWhenNoKeyMatches() async throws {
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: unstoredKey, id: UUID().uuidString)

        do {
            _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
            XCTFail("Expected decryption to fail")
        } catch let error as SecretFilesError {
            guard case .decryptError = error else {
                return XCTFail("Expected the existing decryptError, got \(error)")
            }
        }
    }

    // MARK: - Stamp-on-open (local-only gate)

    func testOpenStampsLocalFile() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "Fresh files are unstamped")

        _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        XCTAssertEqual(KeyStampSlot.readStamp(url: sourceURL), keyA.stampPrefix, "Open must stamp the confirmed key's prefix")
    }

    func testStaleStampRewrittenOnOpen() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        KeyStampSlot.writeStamp(keyB.stampPrefix, url: sourceURL)

        _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        XCTAssertEqual(KeyStampSlot.readStamp(url: sourceURL), keyA.stampPrefix, "A stale stamp must be corrected on open")
    }

    func testMatchingStampNotRewritten() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: sourceURL)

        let bytesBefore = try Data(contentsOf: sourceURL)
        // The attribute-modification date (ctime) changes on any write or
        // attribute restore, so an unchanged value proves no write happened.
        try await Task.sleep(nanoseconds: 50_000_000)
        let ctimeBefore = try sourceURL.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate

        _ = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        XCTAssertEqual(try Data(contentsOf: sourceURL), bytesBefore)
        let ctimeAfter = try sourceURL.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate
        XCTAssertEqual(ctimeBefore, ctimeAfter, "A matching stamp must not be rewritten")
    }

    func testICloudFileNeverStamped() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: keyB)
        let albumManager = FakeICloudAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        let bytesBefore = try Data(contentsOf: sourceURL)

        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext, "iCloud files still get discovery and decrypt")
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytesBefore, "iCloud files must never be written on open")
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL))
    }

    func testStampFailureDoesNotFailOpen() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sourceURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sourceURL.path) }

        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext, "A read-only file must still open normally")
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "The failed stamp write must leave the slot untouched")
    }

    // MARK: - Discovery memo

    /// iCloud-modeled access, so files stay unstamped and only the in-memory
    /// memo can spare repeated opens the discovery sweep.
    private func makeICloudDiskAccess(keyManager: DemoKeyManager) async -> DiskFileAccess {
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: keyB)
        let albumManager = FakeICloudAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)
        return diskAccess
    }

    private func open(_ encrypted: EncryptedMedia, with diskAccess: DiskFileAccess) async throws -> Data {
        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
        guard case .data(let data) = decrypted.source else {
            throw SecretFilesError.decryptError("Expected in-memory data")
        }
        return data
    }

    func testSecondOpenSkipsDiscovery() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)

        let firstOpen = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(firstOpen, plaintext)
        XCTAssertGreaterThanOrEqual(keyManager.storedKeysCalls, 1, "First open of an unstamped file runs discovery")
        XCTAssertNil(KeyStampSlot.readStamp(url: sourceURL), "iCloud-modeled files stay unstamped")

        keyManager.storedKeysCalls = 0
        let secondOpen = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(secondOpen, plaintext)
        XCTAssertEqual(keyManager.storedKeysCalls, 0, "Second open must resolve via the memo, with no discovery sweep")
    }

    func testStaleMemoFallsThroughToDiscovery() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let id = UUID().uuidString
        let encrypted = try await encryptFixture(with: keyA, id: id)
        let sourceURL = try XCTUnwrap(encrypted.url)
        _ = try await open(encrypted, with: diskAccess)

        // Replace the file with one encrypted by a different key: the memo
        // entry for this media id is now stale.
        try FileManager.default.removeItem(at: sourceURL)
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: id)
        let handler = SecretFileHandlerV2(keyBytes: keyB.keyBytes, source: cleartext, targetURL: sourceURL)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())

        keyManager.storedKeysCalls = 0
        let reopened = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(reopened, plaintext, "A stale memo must degrade to rediscovery, not a failed open")
        XCTAssertGreaterThanOrEqual(keyManager.storedKeysCalls, 1, "The stale memo entry must fall through to discovery")

        keyManager.storedKeysCalls = 0
        _ = try await open(encrypted, with: diskAccess)
        XCTAssertEqual(keyManager.storedKeysCalls, 0, "The memo must now map to the replacement key")
    }

    func testMemoNotConsultedAcrossInstances() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let firstAccess = await makeICloudDiskAccess(keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        _ = try await open(encrypted, with: firstAccess)

        let secondAccess = await makeICloudDiskAccess(keyManager: keyManager)
        keyManager.storedKeysCalls = 0
        _ = try await open(encrypted, with: secondAccess)
        XCTAssertGreaterThanOrEqual(keyManager.storedKeysCalls, 1, "A fresh instance starts with an empty memo — no static/global state")
    }

    // MARK: - Born-stamped saves

    /// A tiny real JPEG so `save`'s preview generation succeeds.
    private func makePhotoData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    func testSaveStampsNewLocalFile() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA
        let diskAccess = await makeDiskAccess(albumKey: keyA, keyManager: keyManager)

        let media = CleartextMedia(source: makePhotoData(), mediaType: .photo, id: UUID().uuidString)
        let encrypted = try await diskAccess.save(media: media, metadata: EncryptedFileMetadata(), progress: { _ in })
        let savedURL = try XCTUnwrap(encrypted?.url)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        XCTAssertEqual(KeyStampSlot.readStamp(url: savedURL), keyA.stampPrefix, "New local files must be born stamped")
        XCTAssertEqual(try ExtendedAttributesUtil.getKeyUUID(for: savedURL), keyA.uuid, "The keyUUID xattr must still be written")
    }

    func testSaveDoesNotStampICloudFile() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA
        let album = Album(name: "DiskFileAccessTests-\(UUID().uuidString)", storageOption: .icloud, creationDate: Date(), key: keyA)
        let albumManager = FakeICloudAlbumManager()
        albumManager.keyManager = keyManager
        let diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)

        let media = CleartextMedia(source: makePhotoData(), mediaType: .photo, id: UUID().uuidString)
        let encrypted = try await diskAccess.save(media: media, metadata: EncryptedFileMetadata(), progress: { _ in })
        let savedURL = try XCTUnwrap(encrypted?.url)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        XCTAssertNil(KeyStampSlot.readStamp(url: savedURL), "iCloud saves must leave the slot zero")
        XCTAssertEqual(try ExtendedAttributesUtil.getKeyUUID(for: savedURL), keyA.uuid)
    }

    func testSavedFileOpensViaStampWithoutDiscovery() async throws {
        let keyManager = DemoKeyManager(keys: [keyB, keyA])
        keyManager.currentKey = keyA
        let diskAccess = await makeDiskAccess(albumKey: keyA, keyManager: keyManager)

        let media = CleartextMedia(source: makePhotoData(), mediaType: .photo, id: UUID().uuidString)
        let encrypted = try await diskAccess.save(media: media, metadata: EncryptedFileMetadata(), progress: { _ in })
        let savedURL = try XCTUnwrap(encrypted?.url)
        defer { try? FileManager.default.removeItem(at: savedURL) }

        var attempts: [String] = []
        let result = await KeyDiscovery.discoverKey(for: savedURL, keyManager: keyManager, onAttempt: { attempts.append($0.name) })
        XCTAssertEqual(attempts, ["keyA"], "A born-stamped file must resolve with a single test-decrypt, no sweep")
        XCTAssertEqual(result?.key, keyA)
        XCTAssertEqual(result?.stampMatched, true)
    }

    func testXattrHintStillHonored() async throws {
        let keyManager = SpyKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        let diskAccess = await makeDiskAccess(albumKey: keyB, keyManager: keyManager)

        let encrypted = try await encryptFixture(with: keyA, id: UUID().uuidString)
        let sourceURL = try XCTUnwrap(encrypted.url)
        try ExtendedAttributesUtil.setKeyUUID(keyA.uuid, for: sourceURL)

        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })

        guard case .data(let data) = decrypted.source else {
            return XCTFail("Expected in-memory data")
        }
        XCTAssertEqual(data, plaintext)
        XCTAssertEqual(keyManager.keyWithUUIDCalls, [keyA.uuid], "The xattr hint must be consulted for key resolution")
    }
    func testTotalStoredMediaCountCountsNormalPhoto() async throws {
        let fileManager = FileManager.default
        let testRoot = LocalStorageModel.albumsURL
            .appendingPathComponent("EncameraCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let diskAccess = DiskFileAccess()
        let baseline = await diskAccess.totalStoredMediaCount()

        let photoID = UUID().uuidString
        let photoURL = testRoot.appendingPathComponent("\(photoID).\(MediaType.photo.encryptedFileExtension)")
        XCTAssertTrue(fileManager.createFile(atPath: photoURL.path, contents: Data()))

        let after = await diskAccess.totalStoredMediaCount()
        XCTAssertEqual(after - baseline, 1)
    }

    func testTotalStoredMediaCountCountsLivePhotoOnce() async throws {
        let fileManager = FileManager.default
        let testRoot = LocalStorageModel.albumsURL
            .appendingPathComponent("EncameraCoreTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let diskAccess = DiskFileAccess()
        let baseline = await diskAccess.totalStoredMediaCount()

        let liveID = UUID().uuidString
        let photoURL = testRoot.appendingPathComponent("\(liveID).\(MediaType.photo.encryptedFileExtension)")
        let videoURL = testRoot.appendingPathComponent("\(liveID).\(MediaType.video.encryptedFileExtension)")
        XCTAssertTrue(fileManager.createFile(atPath: photoURL.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: videoURL.path, contents: Data()))

        let after = await diskAccess.totalStoredMediaCount()
        XCTAssertEqual(after - baseline, 1)
    }
}
