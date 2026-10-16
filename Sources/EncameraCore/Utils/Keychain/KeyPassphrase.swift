//
//  KeyPassphrase.swift
//  Encamera
//

import Foundation

public struct KeyPassphrase: Codable, Hashable, Identifiable {
    public let words: [String]
    /// The `PrivateKey.keyFingerprint` of the key these words derive, read from
    /// the keychain item's account. Nil for a passphrase not read from the keychain.
    public let keyFingerprint: String?
    public var keyStampPrefix: UInt32? {
        try? PrivateKey(passphrase: self).stampPrefix
    }

    public var id: String {
        joinedString
    }

    public var joinedString: String {
        words.joined(separator: "-")
    }

    public var joinedStringData: Data? {
        joinedString.data(using: .utf8)
    }

    public init(words: [String], keyFingerprint: String? = nil) {
        self.words = words
        self.keyFingerprint = keyFingerprint
    }

    public init?(keychainValue: [String: Any]) {
        guard let passphraseString = keychainValue[kSecValueData as String] as? Data, let parsedPassphrase = String(data: passphraseString, encoding: .utf8) else { return nil }
        let componentWords = parsedPassphrase.components(separatedBy: "-")
        self.words = componentWords
        self.keyFingerprint = keychainValue[kSecAttrAccount as String] as? String
    }
}
