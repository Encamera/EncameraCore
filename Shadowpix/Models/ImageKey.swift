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

struct ImageKey: Codable {
    
    var keyData: Data
    var name: String
    
    
    init(keyData: Data, name: String) {
        self.keyData = keyData
        self.name = name
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
