import XCTest
@testable import EncameraCore

final class KeyPassphraseTests: XCTestCase {

    func testKeychainItemAccountIsTheKeyFingerprint() {
        let item: [String: Any] = [
            kSecValueData as String: Data("apple-river-stone".utf8),
            kSecAttrAccount as String: "54e07b52aabbccdd54e07b52aabbccdd",
        ]

        let passphrase = KeyPassphrase(keychainValue: item)

        XCTAssertEqual(passphrase?.words, ["apple", "river", "stone"])
        XCTAssertEqual(passphrase?.keyFingerprint, "54e07b52aabbccdd54e07b52aabbccdd")
    }

    func testKeychainItemWithoutAccountHasNoFingerprint() {
        let passphrase = KeyPassphrase(keychainValue: [kSecValueData as String: Data("apple-river".utf8)])

        XCTAssertNil(passphrase?.keyFingerprint)
    }

    func testIdentityIsTheWords() {
        XCTAssertEqual(KeyPassphrase(words: ["a", "b"], keyFingerprint: "x").id,
                       KeyPassphrase(words: ["a", "b"]).id)
    }
}
