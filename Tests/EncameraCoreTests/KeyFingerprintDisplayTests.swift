import XCTest
@testable import EncameraCore

final class KeyFingerprintDisplayTests: XCTestCase {

    private var tempDirectory: URL!
    private let keyA = PrivateKey(keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

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

    func testLabelIsStampHex() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: url)

        let expectedHex = KeyFingerprint.displayLabel(stampPrefix: keyA.stampPrefix)
        XCTAssertEqual(KeyFingerprintDisplay.label(for: url), expectedHex)
    }

    func testLabelNilForUnstampedFile() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        XCTAssertNil(KeyFingerprintDisplay.label(for: url))
    }

    func testLabelNilForGarbageFile() throws {
        let garbageURL = tempDirectory.appendingPathComponent("garbage.enc")
        try Data("not an encrypted file".utf8).write(to: garbageURL)
        XCTAssertNil(KeyFingerprintDisplay.label(for: garbageURL))

        let emptyURL = tempDirectory.appendingPathComponent("empty.enc")
        try Data().write(to: emptyURL)
        XCTAssertNil(KeyFingerprintDisplay.label(for: emptyURL))

        let missingURL = tempDirectory.appendingPathComponent("missing.enc")
        XCTAssertNil(KeyFingerprintDisplay.label(for: missingURL))
    }
}
