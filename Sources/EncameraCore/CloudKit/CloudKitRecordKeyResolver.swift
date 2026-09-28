//
//  CloudKitRecordKeyResolver.swift
//  EncameraCore
//
//  Which key opens one CloudKit record's ciphertext.
//

import Foundation

/// Resolves the key for one CloudKit record's ciphertext, per record, by proof.
///
/// A move never re-encrypts: a CloudKit → CloudKit move re-parents the record on
/// the server, and a local → CloudKit move uploads the file's ciphertext as it is.
/// So a CloudKit album can hold records written under a key other than its own,
/// and the album's key is only the likeliest candidate.
///
/// The record's `keyFingerprint` is a hint for which key to try first, never the
/// answer, because it is not covered by the AEAD. The proof is authenticating the
/// first block (ENC1/ENC2) or chunk 0 (ENC3), from bytes the reader already has:
/// the downloaded file, or the header and chunk 0 a stream fetched first.
///
/// Order: the key this record resolved to earlier in the session, then the album
/// key, then `KeyDiscovery.resolveKey` over the key library with the hint first.
/// The album-key path never reads the key library, which is a full keychain query.
struct CloudKitRecordKeyResolver: DebugPrintable {

    private let albumKey: PrivateKey
    private let keyManager: KeyManager
    /// The key each record resolved to, for the life of the owning file access.
    /// Re-proven on every use; a hit only saves the library read.
    private var resolved: [String: PrivateKey] = [:]

    init(albumKey: PrivateKey, keyManager: KeyManager) {
        self.albumKey = albumKey
        self.keyManager = keyManager
    }

    /// The key that opens the record's ciphertext.
    ///
    /// - Parameter probe: the record's first block, or nil when its bytes do not
    ///   parse as encrypted media. Unparseable bytes prove nothing, so the album key
    ///   is returned and the decrypt fails the way damaged bytes always have.
    /// - Throws: `FileAccessError.missingKeyForMedia` when the bytes are well formed
    ///   and no held key authenticates them. The required key is named by the
    ///   file's stamp, else by the record's fingerprint when it names a key this
    ///   device does not hold.
    mutating func key(forRecordName recordName: String,
                      fingerprintHint hint: String?,
                      probe: FirstBlockProbe?) throws -> PrivateKey {
        guard let probe else {
            printDebug("key UNREADABLE recordName=\(recordName) — first block does not parse; using the album key")
            return albumKey
        }
        if let earlier = resolved[recordName], probe.authenticates(keyBytes: earlier.keyBytes) {
            return earlier
        }
        if probe.authenticates(keyBytes: albumKey.keyBytes) {
            resolved[recordName] = albumKey
            return albumKey
        }

        let storedKeys = (try? keyManager.storedKeys()) ?? []
        let resolution = KeyDiscovery(keyManager: keyManager)
            .resolveKey(hint: hint, storedKeysSnapshot: storedKeys) { probe.authenticates(keyBytes: $0.keyBytes) }
        if case .resolved(let key) = resolution {
            printDebug("key resolved recordName=\(recordName) key=\(key.keychainLabel.prefix(8)) hintMatched=\(hint == key.keychainLabel)")
            resolved[recordName] = key
            return key
        }

        let heldPrefixes = Set((storedKeys + [albumKey]).map(\.stampPrefix))
        if let stamp = probe.stamp, heldPrefixes.contains(stamp) {
            printDebug("key UNREADABLE recordName=\(recordName) — stamped with a held key that fails to authenticate; using the album key")
            return albumKey
        }
        let hintPrefix = hint.flatMap(CloudKitKeyStamp.stampPrefix(fromFingerprintHex:))
            .flatMap { heldPrefixes.contains($0) ? nil : $0 }
        let required = probe.stamp ?? hintPrefix
        printDebug("key MISSING recordName=\(recordName) keysTried=\(storedKeys.count + 1) stamped=\(probe.stamp != nil) hinted=\(hint != nil)")
        throw FileAccessError.missingKeyForMedia(requiredStampPrefix: required)
    }
}
