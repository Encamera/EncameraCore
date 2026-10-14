//
//  ImageKey.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation
import Sodium

enum ImageKeyEncodingError: Error {
    case invalidKeychainItemData
}

public typealias KeyBytes = Array<UInt8>

public struct PrivateKey: Hashable {

    public private(set) var savedToiCloud: Bool = false
    public var creationDate: Date

    private var keyCore: KeyCore
    private struct KeyCore: Codable, Hashable {
        var keyBytes: KeyBytes
        var uuid: UUID

        init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<PrivateKey.KeyCore.CodingKeys> = try decoder.container(keyedBy: PrivateKey.KeyCore.CodingKeys.self)
            let keyData = try container.decode(KeyBytes.self, forKey: PrivateKey.KeyCore.CodingKeys.keyBytes)
            let keyBytes = try keyData.withUnsafeBytes({ (body: UnsafeRawBufferPointer) throws -> [UInt8] in
                        [UInt8](UnsafeRawBufferPointer(body))
                    })
            self.keyBytes = keyBytes
            self.uuid = try container.decode(UUID.self, forKey: PrivateKey.KeyCore.CodingKeys.uuid)
        }

        init(keyBytes: KeyBytes, uuid: UUID) {
            self.keyBytes = keyBytes
            self.uuid = uuid
        }
    }

    public var keyBytes: KeyBytes {
        return keyCore.keyBytes
    }

    public var uuid: UUID {
        return keyCore.uuid
    }

    public var keyData: Data {
        return try! JSONEncoder().encode(self.keyCore)
    }

    /// Stable keychain identity: lowercase hex of the 16-byte key fingerprint.
    ///
    /// Deliberately not `uuid`, which is minted fresh in
    /// `init(name:keyBytes:creationDate:)` and so differs between two
    /// re-derivations of the same key phrase. The fingerprint is a pure
    /// function of the key bytes, so the same key yields the same label on
    /// every device and across imports.
    public var keyFingerprint: String {
        KeyFingerprint.fingerprint(keyBytes: keyBytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// True when `label` looks like a fingerprint hex string rather than a
    /// legacy display name — used to decide whether an item needs relabelling.
    static func isFingerprintLabel(_ label: String) -> Bool {
        label.count == 32 && label.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    public init(keyData: Data, creationDate: Date) throws {
        self.creationDate = creationDate
        self.keyCore = try JSONDecoder().decode(KeyCore.self, from: keyData)
    }

    public init(keyBytes: Array<UInt8>, creationDate: Date) {
        self.keyCore = KeyCore(keyBytes: keyBytes, uuid: UUID())
        self.creationDate = creationDate
    }

    init(keychainItem: [String: Any]) throws {
        guard
            let keyData = keychainItem[kSecValueData as String] as? Data,
            let creationDate = keychainItem[kSecAttrCreationDate as String] as? Date else {
            throw ImageKeyEncodingError.invalidKeychainItemData
        }
        do {
            try self.init(keyData: keyData, creationDate: creationDate)
        } catch {
            let keyBytes = try keyData.withUnsafeBytes({ (body: UnsafeRawBufferPointer) throws -> [UInt8] in
                [UInt8](UnsafeRawBufferPointer(body))
            })
            self.init(keyBytes: keyBytes, creationDate: creationDate)
        }
        if let synced = keychainItem[kSecAttrSynchronizable as String] as? Bool, synced == true {
            self.savedToiCloud = true
        }
    }
}

extension PrivateKey: Identifiable {

    public var id: Array<UInt8>  {
        keyBytes
    }
}

extension PrivateKey: Equatable {

    public static func ==(lhs: PrivateKey, rhs: PrivateKey) -> Bool {
        return lhs.keyBytes == rhs.keyBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyBytes)
    }
    public var keyString: String {
        return keyBytes.map({String($0)}).joined(separator: " ")
    }
}
