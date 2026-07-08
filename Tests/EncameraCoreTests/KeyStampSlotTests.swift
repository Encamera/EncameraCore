import XCTest
@testable import EncameraCore

final class KeyStampSlotTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyStampSlotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func writeTempFile(_ data: Data, name: String = "file.enc") throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Synthetic v1 file: 24-byte stream header, 8-byte block-size field, one content byte.
    private func syntheticV1File(blockSizeField: [UInt8]) -> Data {
        precondition(blockSizeField.count == 8)
        var data = Data(repeating: 0xAA, count: 24)
        data.append(contentsOf: blockSizeField)
        data.append(contentsOf: [0x01])
        return data
    }

    /// Synthetic v2 file: 12-byte header, metadata, then v1-compatible content.
    private func syntheticV2File(metadataLength: UInt32, blockSizeField: [UInt8], truncateAfterHeader: Bool = false) -> Data {
        precondition(blockSizeField.count == 8)
        var data = Data(EncryptedFileFormat.magic)
        data.append(contentsOf: withUnsafeBytes(of: EncryptedFileFormat.version.littleEndian) { Array($0) })
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: withUnsafeBytes(of: metadataLength.littleEndian) { Array($0) })
        if truncateAfterHeader {
            return data
        }
        data.append(Data(repeating: 0xBB, count: Int(metadataLength)))
        data.append(Data(repeating: 0xAA, count: 24))
        data.append(contentsOf: blockSizeField)
        data.append(contentsOf: [0x01])
        return data
    }

    func testOffsetForV1File() throws {
        let blockSizeField: [UInt8] = [0x00, 0x50, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]
        let url = try writeTempFile(syntheticV1File(blockSizeField: blockSizeField))

        let offset = try XCTUnwrap(KeyStampSlot.stampOffset(for: url))
        XCTAssertEqual(offset, 28)

        let fileData = try Data(contentsOf: url)
        XCTAssertEqual(Array(fileData[Int(offset)..<Int(offset) + 4]), [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testOffsetForV2FileWithMetadata() throws {
        let metadataLength: UInt32 = 100
        let blockSizeField: [UInt8] = [0x00, 0x50, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]
        let url = try writeTempFile(syntheticV2File(metadataLength: metadataLength, blockSizeField: blockSizeField))

        let offset = try XCTUnwrap(KeyStampSlot.stampOffset(for: url))
        XCTAssertEqual(offset, 12 + UInt64(metadataLength) + 24 + 4)

        let fileData = try Data(contentsOf: url)
        XCTAssertEqual(Array(fileData[Int(offset)..<Int(offset) + 4]), [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testOffsetForV2FileRealEncrypt() async throws {
        let keyBytes: KeyBytes = Array(repeating: 0x42, count: 32)
        let cleartext = CleartextMedia(source: Data(repeating: 0xCD, count: 30000), mediaType: .photo, id: "stampoffset")
        let destinationURL = tempDirectory.appendingPathComponent("stampoffset.encifile")

        let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: cleartext, targetURL: destinationURL)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())

        let offset = try XCTUnwrap(KeyStampSlot.stampOffset(for: destinationURL))
        let fileData = try Data(contentsOf: destinationURL)
        XCTAssertEqual(Array(fileData[Int(offset)..<Int(offset) + 4]), [0, 0, 0, 0], "The stamp slot must be written-as-zero by the shipped encoder")

        // The 4 bytes before the slot are the used half of the block-size
        // field and must be nonzero (the actual block size).
        let blockSize = fileData[Int(offset) - 4..<Int(offset)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertGreaterThan(blockSize, 0)
    }

    func testOffsetNilForShortFile() throws {
        let url = try writeTempFile(Data(repeating: 0xAA, count: 10))
        XCTAssertNil(KeyStampSlot.stampOffset(for: url))
    }

    func testOffsetNilForEmptyFile() throws {
        let url = try writeTempFile(Data())
        XCTAssertNil(KeyStampSlot.stampOffset(for: url))
    }

    func testOffsetNilForOversizedMetadataLength() throws {
        var data = syntheticV2File(metadataLength: EncryptedFileFormat.maxMetadataSize + 1, blockSizeField: Array(repeating: 0, count: 8), truncateAfterHeader: true)
        data.append(Data(repeating: 0xBB, count: 64))
        let url = try writeTempFile(data)
        XCTAssertNil(KeyStampSlot.stampOffset(for: url))
    }

    func testOffsetNilForMissingFile() {
        XCTAssertNil(KeyStampSlot.stampOffset(for: tempDirectory.appendingPathComponent("does-not-exist.enc")))
    }

    // MARK: - readStamp / writeStamp

    private func assertOnlySlotChanged(before: Data, after: Data, offset: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before.count, after.count, "File length changed", file: file, line: line)
        XCTAssertEqual(before.prefix(offset), after.prefix(offset), "Bytes before the slot changed", file: file, line: line)
        XCTAssertEqual(before.suffix(from: offset + 4), after.suffix(from: offset + 4), "Bytes after the slot changed", file: file, line: line)
    }

    func testWriteReadRoundTripV1() throws {
        let url = try writeTempFile(syntheticV1File(blockSizeField: [0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        let before = try Data(contentsOf: url)
        let offset = try XCTUnwrap(KeyStampSlot.stampOffset(for: url))

        XCTAssertNil(KeyStampSlot.readStamp(url: url))
        KeyStampSlot.writeStamp(0xCAFEBABE, url: url)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), 0xCAFEBABE)

        let after = try Data(contentsOf: url)
        assertOnlySlotChanged(before: before, after: after, offset: Int(offset))
    }

    func testWriteReadRoundTripV2() throws {
        let url = try writeTempFile(syntheticV2File(metadataLength: 100, blockSizeField: [0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        let before = try Data(contentsOf: url)
        let offset = try XCTUnwrap(KeyStampSlot.stampOffset(for: url))

        XCTAssertNil(KeyStampSlot.readStamp(url: url))
        KeyStampSlot.writeStamp(0xDEADBEEF, url: url)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), 0xDEADBEEF)

        let after = try Data(contentsOf: url)
        assertOnlySlotChanged(before: before, after: after, offset: Int(offset))
    }

    func testReadStampNilOnFreshFile() async throws {
        let keyBytes: KeyBytes = Array(repeating: 0x42, count: 32)
        let cleartext = CleartextMedia(source: Data(repeating: 0xCD, count: 5000), mediaType: .photo, id: "fresh")
        let destinationURL = tempDirectory.appendingPathComponent("fresh.encifile")
        let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: cleartext, targetURL: destinationURL)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())

        XCTAssertNil(KeyStampSlot.readStamp(url: destinationURL))
    }

    func testReadStampNilOnZeroWrite() throws {
        let url = try writeTempFile(syntheticV1File(blockSizeField: [0x00, 0x50, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]))
        KeyStampSlot.writeStamp(0, url: url)
        XCTAssertNil(KeyStampSlot.readStamp(url: url))
    }

    func testModificationDatePreserved() throws {
        let url = try writeTempFile(syntheticV1File(blockSizeField: Array(repeating: 0, count: 8)))
        let knownDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: knownDate], ofItemAtPath: url.path)

        KeyStampSlot.writeStamp(0x12345678, url: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(modificationDate.timeIntervalSince1970, knownDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), 0x12345678)
    }

    func testWriteStampNoOpOnGarbageFile() throws {
        let garbage = Data("not an encrypted file".utf8)
        let url = try writeTempFile(garbage, name: "garbage.txt")
        KeyStampSlot.writeStamp(0xCAFEBABE, url: url)
        XCTAssertEqual(try Data(contentsOf: url), garbage)

        let emptyURL = try writeTempFile(Data(), name: "empty.enc")
        KeyStampSlot.writeStamp(0xCAFEBABE, url: emptyURL)
        XCTAssertEqual(try Data(contentsOf: emptyURL), Data())

        KeyStampSlot.writeStamp(0xCAFEBABE, url: tempDirectory.appendingPathComponent("missing.enc"))
    }

    func testOverwriteExistingStamp() throws {
        let url = try writeTempFile(syntheticV1File(blockSizeField: Array(repeating: 0, count: 8)))
        KeyStampSlot.writeStamp(0x11111111, url: url)
        KeyStampSlot.writeStamp(0x22222222, url: url)
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), 0x22222222)
    }

    // MARK: - Old-reader compatibility
    //
    // The zero-format-risk claim rests on one property: every shipped read
    // path loads only bytes 0–3 of the block-size field, so a stamp in bytes
    // 4–7 is invisible to old app versions. These tests decrypt stamped files
    // with the UNMODIFIED handlers — if anyone ever widens a block-size read
    // to 8 bytes, they fail before the change ships.

    private let compatKeyBytes: KeyBytes = Array(repeating: 0x42, count: 32)

    /// Multi-block plaintext (> 2 × 20480 default block size) so the
    /// block-size value is actually exercised for block iteration.
    private let multiBlockPlaintext = Data((0..<50000).map { UInt8($0 % 251) })

    private func encryptV2Fixture(_ plaintext: Data, name: String) async throws -> URL {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: name)
        let url = tempDirectory.appendingPathComponent("\(name).encifile")
        let handler = SecretFileHandlerV2(keyBytes: compatKeyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return url
    }

    private func encryptV1Fixture(_ plaintext: Data, name: String) async throws -> URL {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: name)
        let url = tempDirectory.appendingPathComponent("\(name).encifile")
        let handler = SecretFileHandler(keyBytes: compatKeyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encrypt()
        return url
    }

    private func decryptWithV1Handler(_ url: URL) async throws -> Data {
        let encrypted = try XCTUnwrap(EncryptedMedia(source: url))
        let handler = SecretFileHandler(keyBytes: compatKeyBytes, source: encrypted)
        let decrypted = try await handler.decryptInMemory()
        guard case .data(let data) = decrypted.source else {
            throw XCTSkip("Expected in-memory data")
        }
        return data
    }

    private func decryptWithV2Handler(_ url: URL) async throws -> Data {
        let encrypted = try XCTUnwrap(EncryptedMedia(source: url))
        let handler = SecretFileHandlerV2(keyBytes: compatKeyBytes, source: encrypted)
        let decrypted = try await handler.decryptInMemory()
        guard case .data(let data) = decrypted.source else {
            throw XCTSkip("Expected in-memory data")
        }
        return data
    }

    func testStampedV2FileDecryptsWithUnmodifiedHandler() async throws {
        let url = try await encryptV2Fixture(multiBlockPlaintext, name: "compat-v2")
        KeyStampSlot.writeStamp(0xCAFEBABE, url: url)

        // Both shipped v2 read paths: SecretFileHandlerV2 and SecretFileHandler's v2 branch.
        let viaV2Handler = try await decryptWithV2Handler(url)
        XCTAssertEqual(viaV2Handler, multiBlockPlaintext)
        let viaV1Handler = try await decryptWithV1Handler(url)
        XCTAssertEqual(viaV1Handler, multiBlockPlaintext)
    }

    func testStampedV1FileDecryptsWithUnmodifiedHandler() async throws {
        let url = try await encryptV1Fixture(multiBlockPlaintext, name: "compat-v1")
        KeyStampSlot.writeStamp(0xCAFEBABE, url: url)

        let decrypted = try await decryptWithV1Handler(url)
        XCTAssertEqual(decrypted, multiBlockPlaintext)
    }

    func testRestampedFileStillDecrypts() async throws {
        let url = try await encryptV2Fixture(multiBlockPlaintext, name: "compat-restamp")
        KeyStampSlot.writeStamp(0x11111111, url: url)
        KeyStampSlot.writeStamp(0x22222222, url: url)

        let decrypted = try await decryptWithV2Handler(url)
        XCTAssertEqual(decrypted, multiBlockPlaintext)
    }

    func testMaxPrefixStampStillDecrypts() async throws {
        // All-ones in the dead bytes — the harshest case for any code that
        // accidentally reads the block-size field as 8 bytes.
        let v2URL = try await encryptV2Fixture(multiBlockPlaintext, name: "compat-max-v2")
        KeyStampSlot.writeStamp(0xFFFFFFFF, url: v2URL)
        let v2Decrypted = try await decryptWithV2Handler(v2URL)
        XCTAssertEqual(v2Decrypted, multiBlockPlaintext)

        let v1URL = try await encryptV1Fixture(multiBlockPlaintext, name: "compat-max-v1")
        KeyStampSlot.writeStamp(0xFFFFFFFF, url: v1URL)
        let v1Decrypted = try await decryptWithV1Handler(v1URL)
        XCTAssertEqual(v1Decrypted, multiBlockPlaintext)
    }

    func testMultiBlockStampedFileDecryptsFullyToURL() async throws {
        // The streaming decrypt-to-URL path must also ignore the stamp.
        let sourceURL = try await encryptV2Fixture(multiBlockPlaintext, name: "compat-stream")
        KeyStampSlot.writeStamp(0xCAFEBABE, url: sourceURL)

        let encrypted = try XCTUnwrap(EncryptedMedia(source: sourceURL))
        let destinationURL = tempDirectory.appendingPathComponent("compat-stream-decrypted.bin")
        let handler = SecretFileHandlerV2(keyBytes: compatKeyBytes, source: encrypted, targetURL: destinationURL)
        _ = try await handler.decryptToURL()

        XCTAssertEqual(try Data(contentsOf: destinationURL), multiBlockPlaintext)
    }
}
