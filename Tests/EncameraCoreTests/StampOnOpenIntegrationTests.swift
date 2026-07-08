import XCTest
@testable import EncameraCore

/// End-to-end lifecycle tests for stamp-on-open: an unstamped foreign-key
/// file is discovered, stamped, and re-resolved via its stamp on reopen —
/// using the real DiskFileAccess, real handlers, and temp directories.
final class StampOnOpenIntegrationTests: XCTestCase {

    private let keyA = PrivateKey(name: "keyA", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB", keyBytes: Array(repeating: 0x24, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    /// Multi-block plaintext (> 20480-byte block size) so discovery and full
    /// decrypts exercise real block iteration.
    private let plaintext = Data((0..<50000).map { UInt8($0 % 251) })

    private var tempDirectory: URL!
    private var keyManager: DemoKeyManager!
    private var diskAccess: DiskFileAccess!
    private var album: Album!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StampOnOpenIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Store keys A and B; make B current. Files encrypted with A simulate
        // media from another device / an older key.
        keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyB
        album = Album(name: "StampOnOpenIntegrationTests-\(UUID().uuidString)", storageOption: .local, creationDate: Date(), key: keyB)
        let albumManager = DemoAlbumManager()
        albumManager.keyManager = keyManager
        diskAccess = DiskFileAccess()
        await diskAccess.configure(for: album, albumManager: albumManager)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        if let album {
            try? FileManager.default.removeItem(at: LocalStorageModel(album: album).baseURL)
        }
    }

    private func encryptFixture(with key: PrivateKey, format: FixtureFormat, at url: URL) async throws {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: url.deletingPathExtension().lastPathComponent)
        switch format {
        case .v1:
            let handler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
            _ = try await handler.encrypt()
        case .v2:
            let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
            _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        }
    }

    private enum FixtureFormat {
        case v1, v2
    }

    private func recordedDiscoveryAttempts(for url: URL) async -> [String] {
        var attempts: [String] = []
        _ = await KeyDiscovery.discoverKey(for: url, keyManager: keyManager, onAttempt: { attempts.append($0.name) })
        return attempts
    }

    private func openInMemory(_ url: URL, id: String) async throws -> Data {
        let encrypted = EncryptedMedia(source: url, mediaType: .photo, id: id)
        let decrypted = try await diskAccess.loadMediaInMemory(media: encrypted, progress: { _ in })
        guard case .data(let data) = decrypted.source else {
            throw SecretFilesError.decryptError("Expected in-memory data")
        }
        return data
    }

    private func runForeignKeyLifecycle(format: FixtureFormat) async throws {
        let id = UUID().uuidString
        let url = tempDirectory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        try await encryptFixture(with: keyA, format: format, at: url)
        XCTAssertNil(KeyStampSlot.readStamp(url: url), "Fixture must start unstamped")

        // Before the first open, resolution needs the sweep: current key B is
        // tried (and rejected) before A.
        let sweepAttempts = await recordedDiscoveryAttempts(for: url)
        XCTAssertEqual(sweepAttempts, ["keyB", "keyA"], "An unstamped foreign-key file resolves via the sweep")

        // First open: correct plaintext, and the file learns its key.
        let firstOpen = try await openInMemory(url, id: id)
        XCTAssertEqual(firstOpen, plaintext)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyA.stampPrefix, "The open must stamp the confirmed key")

        // Reopen: stamp hit — exactly one candidate test-decrypt.
        let stampedAttempts = await recordedDiscoveryAttempts(for: url)
        XCTAssertEqual(stampedAttempts, ["keyA"], "A stamped file must resolve with a single test-decrypt")
        let secondOpen = try await openInMemory(url, id: id)
        XCTAssertEqual(secondOpen, plaintext)
    }

    func testForeignKeyFileDiscoveredStampedAndReresolvedV2() async throws {
        try await runForeignKeyLifecycle(format: .v2)
    }

    func testForeignKeyFileDiscoveredStampedAndReresolvedV1() async throws {
        try await runForeignKeyLifecycle(format: .v1)
    }

    func testWrongXattrHealedEndToEnd() async throws {
        let id = UUID().uuidString
        let url = tempDirectory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        try await encryptFixture(with: keyA, format: .v2, at: url)
        // Stale hint from a restore: the xattr names the wrong key.
        try ExtendedAttributesUtil.setKeyUUID(keyB.uuid, for: url)

        let firstOpen = try await openInMemory(url, id: id)
        XCTAssertEqual(firstOpen, plaintext)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyA.stampPrefix, "The open must heal the file with a correct stamp")

        // The stamp now outranks the still-wrong xattr: single test-decrypt.
        let attempts = await recordedDiscoveryAttempts(for: url)
        XCTAssertEqual(attempts, ["keyA"])
    }

    func testLegacyAlbumPassivelyMigrates() async throws {
        // A pre-change album: unstamped files, mixed formats, all encrypted
        // with the non-current key A.
        let storageModel = LocalStorageModel(album: album)
        try storageModel.initializeDirectories()
        let ids = (0..<4).map { "legacy-\($0)-\(UUID().uuidString)" }
        for (index, id) in ids.enumerated() {
            let url = storageModel.driveURLForMedia(withID: id, type: .photo)
            try await encryptFixture(with: keyA, format: index.isMultiple(of: 2) ? .v1 : .v2, at: url)
            XCTAssertNil(KeyStampSlot.readStamp(url: url))
        }

        for id in ids {
            let url = storageModel.driveURLForMedia(withID: id, type: .photo)
            let data = try await openInMemory(url, id: id)
            XCTAssertEqual(data, plaintext, "Legacy file \(id) must decrypt")
            XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyA.stampPrefix, "Legacy file \(id) must be stamped after opening")
        }
    }

    func testGalleryOrderUnchangedAfterStamping() async throws {
        let storageModel = LocalStorageModel(album: album)
        try storageModel.initializeDirectories()
        let ids = (0..<4).map { "order-\($0)-\(UUID().uuidString)" }
        for (index, id) in ids.enumerated() {
            let url = storageModel.driveURLForMedia(withID: id, type: .photo)
            try await encryptFixture(with: keyA, format: .v2, at: url)
            // Distinct, deliberately shuffled dates so ordering is meaningful.
            let date = Date(timeIntervalSince1970: 1_600_000_000 + Double((index * 7) % 5) * 1000)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }

        let orderBefore: [String] = await diskAccess.enumerateMedia().map { (media: EncryptedMedia) in media.id }
        let datesBefore = try ids.map { id in
            try FileManager.default.attributesOfItem(atPath: storageModel.driveURLForMedia(withID: id, type: .photo).path)[.modificationDate] as? Date
        }

        for id in ids {
            let url = storageModel.driveURLForMedia(withID: id, type: .photo)
            _ = try await openInMemory(url, id: id)
            XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyA.stampPrefix)
        }

        let orderAfter: [String] = await diskAccess.enumerateMedia().map { (media: EncryptedMedia) in media.id }
        let datesAfter = try ids.map { id in
            try FileManager.default.attributesOfItem(atPath: storageModel.driveURLForMedia(withID: id, type: .photo).path)[.modificationDate] as? Date
        }

        XCTAssertEqual(orderBefore, orderAfter, "Stamping must not reorder the gallery")
        XCTAssertEqual(datesBefore, datesAfter, "Stamping must preserve modification dates")
    }
}
