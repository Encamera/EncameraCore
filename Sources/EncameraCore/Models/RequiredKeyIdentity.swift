//
//  RequiredKeyIdentity.swift
//  EncameraCore
//
//  Names the key a locked album or piece of media needs.
//

import Foundation

/// The key something on disk says it was encrypted with.
///
/// A routing hint and a gate for key entry, never proof: the value comes from
/// fields the AEAD does not cover (a CloudKit record, a file's stamp slot), so
/// accepting a key still requires an authenticated decrypt.
public enum RequiredKeyIdentity: Hashable, Sendable {

    /// The full fingerprint hex (`PrivateKey.keychainLabel`), as a CloudKit
    /// album or media record carries it.
    case fingerprint(String)

    /// The 4-byte prefix written into a file's stamp slot.
    case stampPrefix(UInt32)

    /// A fingerprint read from storage, or nil when it is not a well-formed
    /// fingerprint hex string.
    public init?(fingerprintHex: String?) {
        guard let fingerprintHex, PrivateKey.isFingerprintLabel(fingerprintHex) else {
            return nil
        }
        self = .fingerprint(fingerprintHex)
    }

    /// Whether `key` is the key this identity names.
    public func matches(_ key: PrivateKey) -> Bool {
        switch self {
        case .fingerprint(let hex):
            return key.keychainLabel == hex
        case .stampPrefix(let prefix):
            return key.stampPrefix == prefix
        }
    }

    /// The short `XXXX-XXXX` label, identical for both forms of the same key.
    public var displayLabel: String {
        switch self {
        case .fingerprint(let hex):
            return KeyFingerprint.displayLabel(fingerprintHex: hex) ?? hex
        case .stampPrefix(let prefix):
            return KeyFingerprint.displayLabel(stampPrefix: prefix)
        }
    }
}
