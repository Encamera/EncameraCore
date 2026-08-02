//
//  ImageKey.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation
import Sodium

enum ImageKeyEncodingError: Error {
    case invalidBase64Data
    case invalidKeychainItemData
}

public typealias KeyName = String
public typealias KeyBytes = Array<UInt8>

public struct PrivateKey: Codable, Hashable {

    public var name: KeyName
    public private(set) var savedToiCloud: Bool = false
    public var creationDate: Date
    private static let keyPrefix = "com.encamera.key."

    private enum CodingKeys: CodingKey {
        case name
        case creationDate
        case keyCore
    }
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
    public var keychainLabel: String {
        KeyFingerprint.fingerprint(keyBytes: keyBytes)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// True when `label` looks like a fingerprint hex string rather than a
    /// legacy display name — used to decide whether an item needs relabelling.
    static func isFingerprintLabel(_ label: String) -> Bool {
        label.count == 32 && label.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    public init(name: String, keyData: Data, creationDate: Date) throws {
        self.name = name
        self.creationDate = creationDate
        self.keyCore = try JSONDecoder().decode(KeyCore.self, from: keyData)
    }

    public init(name: String, keyBytes: Array<UInt8>, creationDate: Date) {
        self.name = name
        self.keyCore = KeyCore(keyBytes: keyBytes, uuid: UUID())
        self.creationDate = creationDate
    }

    public init(base64String: String) throws {
        guard let data = Data(base64Encoded: base64String) else {
            throw ImageKeyEncodingError.invalidBase64Data
        }
        self = try JSONDecoder().decode(PrivateKey.self, from: data)
    }

    init(keychainItem: [String: Any]) throws {
        guard
            let keyData = keychainItem[kSecValueData as String] as? Data,
            let labelData = keychainItem[kSecAttrLabel as String] as? Data,
            let creationDate = keychainItem[kSecAttrCreationDate as String] as? Date else {
            throw ImageKeyEncodingError.invalidKeychainItemData
        }
        // Post-migration the display name lives in kSecAttrApplicationTag and
        // kSecAttrLabel holds the fingerprint. Pre-migration items carry the
        // name in kSecAttrLabel, so fall back to it.
        let name = PrivateKey.displayName(from: keychainItem)
            ?? PrivateKey.keyName(from: labelData)
        do {
            try self.init(name: name, keyData: keyData, creationDate: creationDate)
        } catch {
            let keyBytes = try keyData.withUnsafeBytes({ (body: UnsafeRawBufferPointer) throws -> [UInt8] in
                [UInt8](UnsafeRawBufferPointer(body))
            })
            self.init(name: name, keyBytes: keyBytes, creationDate: creationDate)
        }
        if let synced = keychainItem[kSecAttrSynchronizable as String] as? Bool, synced == true {
            self.savedToiCloud = true
        }
    }

    private static func keyName(from entry: Data) -> String {
        let name = String(data: entry, encoding: .utf8)!

        return name.replacingOccurrences(of: keyPrefix, with: "")
    }

    /// Reads the display name out of `kSecAttrApplicationTag`. The Security
    /// framework hands key attributes back as `Data`, but the in-memory test
    /// wrapper stores whatever it was given, so accept both representations.
    private static func displayName(from keychainItem: [String: Any]) -> String? {
        let raw = keychainItem[kSecAttrApplicationTag as String]
        let string: String?
        if let data = raw as? Data {
            string = String(data: data, encoding: .utf8)
        } else {
            string = raw as? String
        }
        guard let string, !string.isEmpty else { return nil }
        return string.replacingOccurrences(of: keyPrefix, with: "")
    }

    public var base64String: String? {
        return try? String(data: JSONEncoder().encode(self).base64EncodedData(), encoding: .utf8)
    }

}

extension PrivateKey: Identifiable {

    public var id: Array<UInt8>  {
        keyBytes
    }
}

extension PrivateKey: Equatable {

    public static func ==(lhs: PrivateKey, rhs: PrivateKey) -> Bool {
        return lhs.name == rhs.name && lhs.keyBytes == rhs.keyBytes
    }
    public var keyString: String {
        return keyBytes.map({String($0)}).joined(separator: " ")
    }
}
