//
//  Enums.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.05.22.
//

import Foundation
enum MediaType: Int, CaseIterable {
    case video
    case photo
    
    var title: String {
        switch self {
        case .video:
            return "Video"
        case .photo:
            return "Photo"
        }
    }
    
    var path: String {
        switch self {
        case .video:
            return "video"
        case .photo:
            return "photo"
        }
    }
}

enum CameraMode: Int {
    case photo
    case video
}
