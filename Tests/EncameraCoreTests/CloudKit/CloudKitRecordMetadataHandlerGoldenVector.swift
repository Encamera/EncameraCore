//
//  CloudKitRecordMetadataHandlerGoldenVector.swift
//  EncameraCoreTests
//
//  DO NOT REGENERATE THIS VECTOR. If `testGoldenVectorReads` fails, the sealed
//  format changed: revert the code instead. Records already in CloudKit carry
//  this format, and a build that cannot read them loses their metadata.
//
//  Produced outside EncameraCore by a C program calling libsodium 1.0.22
//  directly: crypto_aead_xchacha20poly1305_ietf_encrypt of `json` under `key`
//  and `nonce`, with additional data "ENCKMETA" + UTF-8 `recordName`,
//  output nonce || ciphertext || tag.
//

import Foundation

enum CloudKitRecordMetadataHandlerGoldenVector {
    /// Bytes 0x00 through 0x1f.
    static let key: [UInt8] = Array(0..<32)
    /// Bytes 0xa0 through 0xb7; the first 24 bytes of `sealedHex`.
    static let nonce: [UInt8] = Array(0xa0...0xb7)
    static let recordName = "golden-record#0"
    /// The plaintext that was sealed.
    static let json = #"{"captureDate":"2017-07-14T02:40:00Z","location":{"latitude":52.52,"longitude":13.405},"originalMediaType":"photo","schemaVersion":1}"#
    static let sealedHex = "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b73ece697cc729d1de042b4cfd141299e2099aae1b8736fdf42c74dfd7d599ca06ebb79a75646a5ea0ca880f22f25bc10c9f5d0495bb1cb9d38fd364c8131440ad5340ca5ec084065af0183f081d7f064eff49ee78237f972030814f60fe30775c4737ca0db819a2391973e9ed60ec4bdcf63ba03ff38efffcbfa53c6d91701b9c3009594ba18f772d8b58468e232d0199a219d8dfd1"
}
