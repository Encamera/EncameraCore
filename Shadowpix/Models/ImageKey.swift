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
    
    init(name: String, keyBytes: Array<UInt8>) {
        self.name = name
        self.keyBytes = keyBytes
    }
    
    init(base64String: String) throws {
        guard let data = Data(base64Encoded: base64String) else {
            throw ImageKeyEncodingError.invalidBase64Data
        }
        self = try JSONDecoder().decode(ImageKey.self, from: data)
    }
    
    var base64String: String? {
        return try? String(data: JSONEncoder().encode(self).base64EncodedData(), encoding: .utf8)
    }
    
}

extension ImageKey: Equatable {
    
}
