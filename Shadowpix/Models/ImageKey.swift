//
//  ImageKey.swift
//  shadowpix
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation

enum ImageKeyEncodingError: Error {
    case invalidBase64Data
}

typealias KeyName = String

struct ImageKey: Codable {
    
    var name: KeyName
    var keyBytes: Array<UInt8>
    var creationDate: Date
    private static let keyPrefix = "com.shadowpix.key."

    @available(*, deprecated, message: "Use init with creation date")
    init(name: String, keyBytes: Array<UInt8>) {
        self.name = name
        self.keyBytes = keyBytes
        self.creationDate = Date()
    }
    
    init(name: String, keyBytes: Array<UInt8>, creationDate: Date) {
        self.name = name
        self.keyBytes = keyBytes
        self.creationDate = creationDate
    }
    
    init(base64String: String) throws {
        guard let data = Data(base64Encoded: base64String) else {
            throw ImageKeyEncodingError.invalidBase64Data
        }
        self = try JSONDecoder().decode(ImageKey.self, from: data)
    }
    
    init(keychainItem: [String: Any]) throws {
        let keyData = keychainItem[kSecValueData as String] as! Data
        let nameData = keychainItem[kSecAttrApplicationTag as String] as! Data
        let creationDate = keychainItem[kSecAttrCreationDate as String] as! Date
        let name = ImageKey.keyName(from: nameData)

        let keyBytes = try keyData.withUnsafeBytes({ (body: UnsafeRawBufferPointer) throws -> [UInt8] in
            [UInt8](UnsafeRawBufferPointer(body))
        })
        self.init(name: name, keyBytes: keyBytes, creationDate: creationDate)
    }
    
    var keychainQueryDict: [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: ImageKey.keychainNameEntry(keyName: name).data(using: .utf8)!,
            kSecAttrCreationDate as String: creationDate,
            kSecValueData as String: Data(keyBytes)
        ]
    }
    
    static func keychainNameEntry(keyName: String) -> String {
        return "\(keyPrefix)\(keyName)"
    }
    
    private static func keyName(from entry: Data) -> String {
        let name = String(data: entry, encoding: .utf8)!

        return name.replacingOccurrences(of: keyPrefix, with: "")
    }
    var base64String: String? {
        return try? String(data: JSONEncoder().encode(self).base64EncodedData(), encoding: .utf8)
    }
    
}

extension ImageKey: Equatable {
    
}
