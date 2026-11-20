//
//  CloudKitRecordMetadataHandler.swift
//  EncameraCore
//
//  Encrypts and reads an item's `EncryptedFileMetadata` for the `EncMedia.encMetadata` field.
//

import Foundation
import Sodium

/// The album-key ciphertext of one item's `EncryptedFileMetadata`, as it sits on
/// an `EncMedia` record.
///
/// Layout: a random 24-byte nonce followed by the XChaCha20-Poly1305-IETF
/// ciphertext and tag of the metadata JSON (`EncryptedMetadataHandler.encodeMetadata`).
/// The additional data is `"ENCKMETA"` plus the UTF-8 record name, so a sealed
/// value copied onto another record does not decrypt there.
public enum CloudKitRecordMetadataHandler: DebugPrintable {

    /// Domain separator for the additional data, distinct from the ENC3 header's
    /// `"ENC3META"`.
    static let additionalDataPrefix = Array("ENCKMETA".utf8)

    public enum EncryptionError: Error {
        case encryptionFailed
    }

    /// Encrypts `metadata` under `keyBytes`, bound to `recordName`.
    public static func encryptMetadata(_ metadata: EncryptedFileMetadata, recordName: String, keyBytes: [UInt8]) throws -> Data {
        let json = try EncryptedMetadataHandler.encodeMetadata(metadata)
        return try encryptMetadata(bytes: json, recordName: recordName, keyBytes: keyBytes)
    }

    /// Encrypts metadata JSON `bytes` exactly as given, under `keyBytes`, bound to
    /// `recordName`. Copying a file's metadata onto its record encrypts the bytes
    /// the file decrypts to (`EncryptedMetadataHandler.readMetadataBytes`), so
    /// keys this build does not know are kept.
    public static func encryptMetadata(bytes: Data, recordName: String, keyBytes: [UInt8]) throws -> Data {
        guard let sealed: Bytes = Sodium().aead.xchacha20poly1305ietf.encrypt(
            message: [UInt8](bytes),
            secretKey: keyBytes,
            additionalData: additionalData(recordName: recordName)
        ) else { throw EncryptionError.encryptionFailed }
        return Data(sealed)
    }

    /// `metadata` encrypted for a new record's `encMetadata` field, or nil when it
    /// cannot be encrypted: the field is optional, so the record saves without it.
    /// A failure is logged by record name only.
    public static func encryptMetadataForRecordField(_ metadata: EncryptedFileMetadata,
                                                     recordName: String,
                                                     keyBytes: [UInt8]) -> Data? {
        do {
            return try encryptMetadata(metadata, recordName: recordName, keyBytes: keyBytes)
        } catch {
            printDebug("encryptMetadata FAILED recordName=\(recordName) — the record saves without encMetadata")
            return nil
        }
    }

    /// Decrypts and decodes the metadata sealed in `sealed`, or nil when the key,
    /// the record name or the bytes do not authenticate, or the JSON does not decode.
    public static func readMetadata(_ sealed: Data, recordName: String, keyBytes: [UInt8]) -> EncryptedFileMetadata? {
        guard let json = Sodium().aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: [UInt8](sealed),
            secretKey: keyBytes,
            additionalData: additionalData(recordName: recordName)
        ) else { return nil }
        return try? EncryptedMetadataHandler.decodeMetadata(Data(json))
    }

    static func additionalData(recordName: String) -> [UInt8] {
        additionalDataPrefix + Array(recordName.utf8)
    }
}
