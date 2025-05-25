//
//  ImageKey.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation
import Sodium


public struct LegacyPrivateKey: Codable, Hashable {

    public var name: KeyName
    public private(set) var keyBytes: KeyBytes
    public private(set) var savedToiCloud: Bool = false
    public var creationDate: Date
    private static let keyPrefix = "com.encamera.key."

    private enum CodingKeys: CodingKey {
        case name
        case keyBytes
        case creationDate
    }

    public init(name: String, keyBytes: Array<UInt8>, creationDate: Date) {
        self.name = name
        self.keyBytes = keyBytes
        self.creationDate = creationDate
    }

    public init(base64String: String) throws {
        guard let data = Data(base64Encoded: base64String) else {
            throw ImageKeyEncodingError.invalidBase64Data
        }
        self = try JSONDecoder().decode(LegacyPrivateKey.self, from: data)
    }

    init(keychainItem: [String: Any]) throws {
        guard
            let keyData = keychainItem[kSecValueData as String] as? Data,
            let nameData = keychainItem[kSecAttrLabel as String] as? Data,
            let creationDate = keychainItem[kSecAttrCreationDate as String] as? Date else {
            throw ImageKeyEncodingError.invalidKeychainItemData
        }
        let name = LegacyPrivateKey.keyName(from: nameData)

        let keyBytes = try keyData.withUnsafeBytes({ (body: UnsafeRawBufferPointer) throws -> [UInt8] in
            [UInt8](UnsafeRawBufferPointer(body))
        })
        self.init(name: name, keyBytes: keyBytes, creationDate: creationDate)
        if let synced = keychainItem[kSecAttrSynchronizable as String] as? Bool, synced == true {
            self.savedToiCloud = true
        }
    }

    private static func keyName(from entry: Data) -> String {
        let name = String(data: entry, encoding: .utf8)!

        return name.replacingOccurrences(of: keyPrefix, with: "")
    }

    public var base64String: String? {
        return try? String(data: JSONEncoder().encode(self).base64EncodedData(), encoding: .utf8)
    }

}

extension LegacyPrivateKey: Identifiable {

    public var id: Array<UInt8>  {
        keyBytes
    }
}

extension LegacyPrivateKey: Equatable {

    public static func ==(lhs: LegacyPrivateKey, rhs: LegacyPrivateKey) -> Bool {
        return lhs.name == rhs.name && lhs.keyBytes == rhs.keyBytes
    }
    public var keyString: String {
        return keyBytes.map({String($0)}).joined(separator: " ")
    }
}
