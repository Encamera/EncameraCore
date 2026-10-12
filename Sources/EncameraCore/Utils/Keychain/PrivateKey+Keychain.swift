//
//  PrivateKey+Keychain.swift
//  Encamera
//

import Foundation
import Security

extension PrivateKey {

    /// The display name, stored outside the item's identity attributes.
    var applicationTagValue: String {
        "\(KeychainConstants.applicationTag).\(name)"
    }

    /// Identity is the fingerprint, written to BOTH `kSecAttrLabel` and
    /// `kSecAttrApplicationLabel`.
    ///
    /// `kSecAttrApplicationLabel` is what actually matters to the Security
    /// framework: for `kSecClassKey` the primary key is the combination of
    /// applicationLabel/applicationTag/keyType/keySizeInBits/effectiveKeySize/
    /// keyClass — `kSecAttrLabel` is NOT part of it. Putting the display name
    /// there (as ENC-78 step 2 originally proposed) would make two keys named
    /// `encamera_default_key` collide with errSecDuplicateItem, which is the
    /// exact thing this ticket exists to fix. `kSecAttrLabel` gets the
    /// fingerprint too because the in-memory test wrapper keys its uniqueness
    /// off label; writing both keeps real and fake keychains in agreement.
    var keychainIdentityAttributes: [String: Any] {
        [
            kSecAttrLabel as String: keychainLabel.data(using: .utf8)!,
            kSecAttrApplicationLabel as String: keychainLabel.data(using: .utf8)!,
            kSecAttrApplicationTag as String: applicationTagValue.data(using: .utf8)!,
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
