//
//  KeyDiscovery.swift
//  EncameraCore
//
//  Resolves which key encrypted a file (see Documentation/plans/stamp-on-open-local-files.md).
//

import Foundation
import Sodium

/// A confirmed answer to "which key encrypted this file?".
public struct KeyDiscoveryResult {
    public let key: PrivateKey
    /// True iff the file's stamp slot already held this key's `stampPrefix` —
    /// the stamping integration uses this to decide whether to (re)write the slot.
    public let stampMatched: Bool
}

public enum KeyDiscovery: DebugPrintable {

    /// Resolves the key that encrypted the file at `sourceURL`, or nil when no
    /// stored key decrypts it. Never throws; performs no writes (no stamping,
    /// no xattr, no memo — that's the caller's job).
    ///
    /// Candidate order: stamp matches → xattr hint → current key → remaining
    /// stored keys, deduplicated by uuid. Every candidate — including the
    /// xattr one, which today's open paths trust without verification — is
    /// confirmed by authenticating the first ciphertext block. The file's
    /// prologue and first block are read once; only the AEAD attempt repeats
    /// per candidate.
    public static func discoverKey(for sourceURL: URL, keyManager: KeyManager) async -> KeyDiscoveryResult? {
        await discoverKey(for: sourceURL, keyManager: keyManager, onAttempt: nil)
    }

    /// Internal variant with an attempt observer so tests can assert
    /// candidate ordering.
    static func discoverKey(
        for sourceURL: URL,
        keyManager: KeyManager,
        onAttempt: ((PrivateKey) -> Void)?
    ) async -> KeyDiscoveryResult? {
        guard let probe = FirstBlockProbe(url: sourceURL) else {
            return nil
        }
        let storedKeys = (try? keyManager.storedKeys()) ?? []
        let stamp = KeyStampSlot.readStamp(url: sourceURL)

        var candidates: [PrivateKey] = []
        var seenUUIDs = Set<UUID>()
        func addCandidate(_ key: PrivateKey?) {
            guard let key, seenUUIDs.insert(key.uuid).inserted else {
                return
            }
            candidates.append(key)
        }

        if let stamp {
            // Two of the user's keys can share a stamp prefix (~k²·2⁻³³), so
            // matches are a list, not a single hit.
            for key in storedKeys where key.stampPrefix == stamp {
                addCandidate(key)
            }
        }
        if let xattrUUID = (try? ExtendedAttributesUtil.getKeyUUID(for: sourceURL)) ?? nil {
            addCandidate(await keyManager.keyWith(uuid: xattrUUID))
        }
        addCandidate(keyManager.currentKey)
        for key in storedKeys {
            addCandidate(key)
        }

        for candidate in candidates {
            onAttempt?(candidate)
            if probe.authenticates(keyBytes: candidate.keyBytes) {
                return KeyDiscoveryResult(key: candidate, stampMatched: stamp != nil && stamp == candidate.stampPrefix)
            }
        }
        return nil
    }

    /// Whether the candidate key authenticates the first ciphertext block of
    /// the file. This is the unit of verification for all key discovery: a
    /// bounded read (headers + one ~20KB block) and one AEAD op. Any I/O
    /// error, malformed prologue, or short read returns false — never throws.
    public static func canDecryptFirstBlock(of url: URL, with key: PrivateKey) async -> Bool {
        guard let probe = FirstBlockProbe(url: url) else {
            return false
        }
        return probe.authenticates(keyBytes: key.keyBytes)
    }
}

/// The stream header and first ciphertext block of an encrypted file, read
/// once so multiple candidate keys can be tried without re-reading the file.
struct FirstBlockProbe {

    /// Upper bound for a plausible first-block length. Both shipped encoders
    /// write 20480-byte plaintext blocks (~20KB ciphertext); anything much
    /// larger means a corrupt block-size field, not a real file.
    private static let maxPlausibleBlockSize: UInt32 = 16 * 1024 * 1024

    let streamHeader: [UInt8]
    let firstBlock: [UInt8]

    init?(url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }
        do {
            // Parse the prologue the same way the shipped handlers do:
            // v2 files start with the ENC2 magic and a metadata section to
            // skip; v1 files start directly with the stream header.
            guard let magicData = try fileHandle.read(upToCount: EncryptedFileFormat.magicSize),
                  magicData.count == EncryptedFileFormat.magicSize else {
                return nil
            }
            let contentStart: UInt64
            if Array(magicData) == EncryptedFileFormat.magic {
                try fileHandle.seek(toOffset: UInt64(EncryptedFileFormat.metadataLengthOffset))
                guard let lengthData = try fileHandle.read(upToCount: EncryptedFileFormat.metadataLengthSize),
                      lengthData.count == EncryptedFileFormat.metadataLengthSize else {
                    return nil
                }
                let metadataLength = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                guard metadataLength <= EncryptedFileFormat.maxMetadataSize else {
                    return nil
                }
                contentStart = UInt64(EncryptedFileFormat.metadataLengthOffset + EncryptedFileFormat.metadataLengthSize) + UInt64(metadataLength)
            } else {
                contentStart = 0
            }

            try fileHandle.seek(toOffset: contentStart)
            let headerSize = EncryptedFileFormat.streamHeaderSize
            guard let headerData = try fileHandle.read(upToCount: headerSize),
                  headerData.count == headerSize else {
                return nil
            }

            // Block-size field: 8 bytes on disk, but only bytes 0–3 are the
            // block size — bytes 4–7 are the stamp slot and must be ignored
            // here, exactly as the shipped readers do.
            guard let blockSizeData = try fileHandle.read(upToCount: 8),
                  blockSizeData.count == 8 else {
                return nil
            }
            let blockSize = UInt32(littleEndian: blockSizeData.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard blockSize > 0, blockSize <= Self.maxPlausibleBlockSize else {
                return nil
            }

            // The first ciphertext block is exactly blockSize bytes (the
            // encoders record the first block's ciphertext length).
            guard let blockData = try fileHandle.read(upToCount: Int(blockSize)),
                  blockData.count == Int(blockSize) else {
                return nil
            }

            self.streamHeader = Array(headerData)
            self.firstBlock = Array(blockData)
        } catch {
            return nil
        }
    }

    /// Whether the key authenticates the first block.
    ///
    /// initPull succeeds with a WRONG key — only pull authenticates.
    /// Returning true from initPull alone would defeat the whole
    /// verification; the pull below is the proof.
    func authenticates(keyBytes: KeyBytes) -> Bool {
        let sodium = Sodium()
        guard let stream = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: streamHeader) else {
            return false
        }
        return stream.pull(cipherText: firstBlock) != nil
    }
}
