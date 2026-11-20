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
public enum CloudKitRecordMetadataHandler {

    /// Domain separator for the additional data, distinct from the ENC3 header's
    /// `"ENC3META"`.
    static let additionalDataPrefix = Array("ENCKMETA".utf8)

    public enum EncryptionError: Error {
        case encryptionFailed
    }

    /// Encrypts `metadata` under `keyBytes`, bound to `recordName`.
    public static func encryptMetadata(_ metadata: EncryptedFileMetadata, recordName: String, keyBytes: [UInt8]) throws -> Data {
        let json = try EncryptedMetadataHandler.encodeMetadata(metadata)
        guard let sealed: Bytes = Sodium().aead.xchacha20poly1305ietf.encrypt(
            message: [UInt8](json),
            secretKey: keyBytes,
            additionalData: additionalData(recordName: recordName)
        ) else { throw EncryptionError.encryptionFailed }
        return Data(sealed)
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
