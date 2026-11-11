//
//  PassphraseKey.swift
//  EncameraCore
//

import Foundation

/// A key together with the passphrase it was derived from.
///
/// This is the only public way to derive a key from a passphrase, and
/// `KeyManager` only saves a phrase-derived key in this form, so a key never
/// enters the library without its passphrase item. Without that item the key
/// cannot be listed in the key picker or backed up.
public struct PassphraseKey: Equatable {

    /// The words `key` was derived from, with `keyFingerprint` naming `key`.
    public let passphrase: KeyPassphrase
    public let key: PrivateKey

    /// Derives the key for `passphrase`. Runs Argon2, so call it off the main
    /// thread.
    public init(passphrase: KeyPassphrase) throws {
        let key = try PrivateKey(passphrase: passphrase)
        self.key = key
        self.passphrase = KeyPassphrase(words: passphrase.words, keyFingerprint: key.keyFingerprint)
    }
}
