//
//  Enums.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.05.22.
//

import Foundation
enum MediaType: Int, CaseIterable {
    case video
    case photos
    case decrypted
    
    var title: String {
        switch self {
        case .video:
            return "Video"
        case .photos:
            return "Photos"
        case .decrypted:
            return "Decrypted"
        }
    }
    
    var path: String {
        switch self {
        case .video:
            return "video"
        case .photos:
            return "photo"
        case .decrypted:
            return "decrypted"
        }
    }
}

enum CameraMode: Int {
    case photo
    case video
}
