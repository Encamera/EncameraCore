import XCTest
import Sodium
@testable import EncameraCore

final class KeyFingerprintTests: XCTestCase {

    private let keyBytes: KeyBytes = Array(0..<32).map { UInt8($0) }

    func testFingerprintIsDeterministic() {
        let first = KeyFingerprint.fingerprint(keyBytes: keyBytes)
        let second = KeyFingerprint.fingerprint(keyBytes: keyBytes)
        XCTAssertEqual(first, second)
    }

    func testFingerprintDiscriminates() {
        var flipped = keyBytes
        flipped[0] ^= 0b0000_0001
        XCTAssertNotEqual(
            KeyFingerprint.fingerprint(keyBytes: keyBytes),
            KeyFingerprint.fingerprint(keyBytes: flipped)
        )
    }

    func testFingerprintLengthIs16Bytes() {
        XCTAssertEqual(KeyFingerprint.fingerprint(keyBytes: keyBytes).count, 16)
    }

    func testStampPrefixIsLittleEndianFirstFourBytes() {
        let fingerprint = KeyFingerprint.fingerprint(keyBytes: keyBytes)
        let expected = UInt32(fingerprint[0])
            | UInt32(fingerprint[1]) << 8
            | UInt32(fingerprint[2]) << 16
            | UInt32(fingerprint[3]) << 24
        XCTAssertEqual(KeyFingerprint.stampPrefix(keyBytes: keyBytes), expected)
    }

    func testFingerprintDiffersFromUnkeyedHash() {
        let unkeyed = Sodium().genericHash.hash(message: keyBytes, outputLength: 16)!
        XCTAssertNotEqual(KeyFingerprint.fingerprint(keyBytes: keyBytes), Data(unkeyed))
    }

    func testPrivateKeysWithSameBytesShareFingerprint() {
        let first = PrivateKey(name: "first", keyBytes: keyBytes, creationDate: Date(timeIntervalSince1970: 0))
        let second = PrivateKey(name: "second", keyBytes: keyBytes, creationDate: Date(timeIntervalSince1970: 1000))
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.stampPrefix, second.stampPrefix)
        XCTAssertEqual(first.fingerprint, KeyFingerprint.fingerprint(keyBytes: keyBytes))
        XCTAssertEqual(first.stampPrefix, KeyFingerprint.stampPrefix(keyBytes: keyBytes))
    }

    // These vectors are frozen. If this test fails, you have changed the
    // on-disk fingerprint format (algorithm, domain-separation key, output
    // length, or endianness) — do not update the vectors; revert the change.
    // Computed independently with Python: hashlib.blake2b(input, key=b"encamera.keyfp.1", digest_size=16).
    func testGoldenVectors() {
        let vectors: [(input: String, fingerprint: String, stampPrefix: UInt32)] = [
            ("0000000000000000000000000000000000000000000000000000000000000000",
             "bb5ff3f1bafa6e3e5b206934869b3c14", 4059258811),
            ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
             "4dae15d38f097bdb6bc81dec9d136afc", 3541413453),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
             "a38caad5a169a82d68f61a39491b09cc", 3584724131),
            ("8f3a1c5db02e47698a4dfe12c7b3055e9d6420fbca1837245f0e9b6d13c8a7f4",
             "54e07b52b99136b861dcbe39fd632a47", 1383850068),
        ]
        for vector in vectors {
            let keyBytes = Self.bytes(fromHex: vector.input)
            let fingerprintHex = KeyFingerprint.fingerprint(keyBytes: keyBytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(fingerprintHex, vector.fingerprint, "Fingerprint drifted for input \(vector.input)")
            XCTAssertEqual(KeyFingerprint.stampPrefix(keyBytes: keyBytes), vector.stampPrefix, "Stamp prefix drifted for input \(vector.input)")
        }
    }

    private static func bytes(fromHex hex: String) -> KeyBytes {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    func testPrivateKeyCodableShapeUnchanged() throws {
        let key = PrivateKey(name: "codable", keyBytes: keyBytes, creationDate: Date(timeIntervalSince1970: 0))
        let encoded = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(PrivateKey.self, from: encoded)
        XCTAssertEqual(decoded, key)
        XCTAssertEqual(decoded.uuid, key.uuid)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertFalse(json.contains("fingerprint"))
        XCTAssertFalse(json.contains("stampPrefix"))
    }
}
