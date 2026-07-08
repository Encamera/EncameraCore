import XCTest
@testable import EncameraCore

final class KeyFingerprintDisplayTests: XCTestCase {

    private var tempDirectory: URL!
    private let keyA = PrivateKey(name: "keyA", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB", keyBytes: Array(repeating: 0x24, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    /// Multi-block plaintext so the first block is a full 20480-byte block.
    private let plaintext = Data((0..<50000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyFingerprintDisplayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func encryptV2Fixture(with key: PrivateKey, name: String = "fixture-v2") async throws -> URL {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: name)
        let url = tempDirectory.appendingPathComponent("\(name).encifile")
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return url
    }

    // Locked to the frozen fingerprint vectors in KeyFingerprintTests: the
    // label is the first four fingerprint bytes in on-disk order, so prefix
    // 1383850068 (fingerprint 54e07b52...) must render as "54E0-7B52".
    func testDisplayLabelMatchesGoldenVector() {
        XCTAssertEqual(KeyFingerprint.displayLabel(stampPrefix: 1383850068), "54E0-7B52")
    }

    func testLabelWithSingleMatchingStoredKey() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: url)

        let expectedHex = KeyFingerprint.displayLabel(stampPrefix: keyA.stampPrefix)
        let label = KeyFingerprintDisplay.label(for: url, storedKeys: [keyA, keyB])
        XCTAssertEqual(label, "keyA (\(expectedHex))")
    }

    func testLabelWithNoMatchingStoredKey() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: url)

        let expectedHex = KeyFingerprint.displayLabel(stampPrefix: keyA.stampPrefix)
        XCTAssertEqual(KeyFingerprintDisplay.label(for: url, storedKeys: [keyB]), expectedHex)
        XCTAssertEqual(KeyFingerprintDisplay.label(for: url, storedKeys: []), expectedHex)
    }

    func testLabelWithCollidingStoredKeys() async throws {
        // The colliding key pair from KeyDiscoveryTests: two real keys whose
        // BLAKE2b stamp prefixes collide. With both stored, the match is
        // ambiguous, so the label must fall back to bare hex — no name.
        let collidingBytes1 = Self.bytes(fromHex: "e1b33d369bf555406f9956543d5b0ae0581a6501cfc70d33c3ff0b64346a1b61")
        let collidingBytes2 = Self.bytes(fromHex: "d0213432d6b5707cd28d27ae4dac8a94c6c18e6c626bcfda3c16be3cf35cb683")
        let collider1 = PrivateKey(name: "collider1", keyBytes: collidingBytes1, creationDate: Date(timeIntervalSince1970: 0))
        let collider2 = PrivateKey(name: "collider2", keyBytes: collidingBytes2, creationDate: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(collider1.stampPrefix, collider2.stampPrefix, "Fixture keys must share a stamp prefix")
        XCTAssertNotEqual(collider1.keyBytes, collider2.keyBytes)

        let url = try await encryptV2Fixture(with: collider2)
        KeyStampSlot.writeStamp(collider2.stampPrefix, url: url)

        let expectedHex = KeyFingerprint.displayLabel(stampPrefix: collider2.stampPrefix)
        let label = KeyFingerprintDisplay.label(for: url, storedKeys: [collider1, collider2])
        XCTAssertEqual(label, expectedHex)
    }

    func testLabelNilForUnstampedFile() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        XCTAssertNil(KeyFingerprintDisplay.label(for: url, storedKeys: [keyA]))
    }

    func testLabelNilForGarbageFile() throws {
        // Same garbage fixture as KeyStampSlotTests: shorter than the v1 slot
        // layout, so readStamp can reject it. (V1 files carry no magic, so a
        // garbage file long enough to contain the slot reads as v1 — the
        // stamp is a routing hint, not proof, and the label reflects that.)
        let garbageURL = tempDirectory.appendingPathComponent("garbage.enc")
        try Data("not an encrypted file".utf8).write(to: garbageURL)
        XCTAssertNil(KeyFingerprintDisplay.label(for: garbageURL, storedKeys: [keyA]))

        let emptyURL = tempDirectory.appendingPathComponent("empty.enc")
        try Data().write(to: emptyURL)
        XCTAssertNil(KeyFingerprintDisplay.label(for: emptyURL, storedKeys: [keyA]))

        let missingURL = tempDirectory.appendingPathComponent("missing.enc")
        XCTAssertNil(KeyFingerprintDisplay.label(for: missingURL, storedKeys: [keyA]))
    }

    private static func bytes(fromHex hex: String) -> KeyBytes {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }
}
