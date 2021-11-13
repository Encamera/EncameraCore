//
//  ImageKey.swift
//  shadowpix
//
//  Created by Alexander Freas on 09.11.21.
//

import Foundation

struct ImageKey: Codable {
    
    var keyData: Data
    var name: String
    
    init(base64String: String) throws {
        let data = Data(base64Encoded: base64String)!
        self = try JSONDecoder().decode(ImageKey.self, from: data)
    }
    
}
