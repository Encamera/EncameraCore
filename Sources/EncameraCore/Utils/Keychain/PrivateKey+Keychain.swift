//
//  PrivateKey+Keychain.swift
//  Encamera
//

import Foundation
import Security

extension PrivateKey {

    /// Identity is the fingerprint, written to BOTH `kSecAttrLabel` and
    /// `kSecAttrApplicationLabel`.
    ///
    /// `kSecAttrApplicationLabel` is what actually matters to the Security
    /// framework: for `kSecClassKey` the primary key is the combination of
    /// applicationLabel/applicationTag/keyType/keySizeInBits/effectiveKeySize/
    /// keyClass — `kSecAttrLabel` is NOT part of it. Every key shares the same
    /// application tag, so the fingerprint in the application label is what
    /// keeps two keys from colliding with errSecDuplicateItem. `kSecAttrLabel` gets the
    /// fingerprint too because the in-memory test wrapper keys its uniqueness
    /// off label; writing both keeps real and fake keychains in agreement.
    var keychainIdentityAttributes: [String: Any] {
        [
            kSecAttrLabel as String: keychainLabel.data(using: .utf8)!,
            kSecAttrApplicationLabel as String: keychainLabel.data(using: .utf8)!,
            kSecAttrApplicationTag as String: KeychainConstants.keyApplicationTag.data(using: .utf8)!,
        ]
    }

    var keychainQueryDictForUpdate: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrCreationDate as String: creationDate,
        ]
        query.merge(keychainIdentityAttributes) { current, _ in current }
        return query
    }

    var keychainQueryDictForKeychain: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrCreationDate as String: creationDate,
            kSecValueData as String: keyData,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        query.merge(keychainIdentityAttributes) { current, _ in current }
        return query
    }
}
