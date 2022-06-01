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
    case unknown
    
    static func typeFromExtension(string: String) -> MediaType {
        switch string {
        case "mov":
            return .video
        case "jpg", "png", "jpeg":
            return .photo
        default:
            return .unknown
        }
    }
    
    var fileExtension: String {
        switch self {
        case .video:
            return "mov"
        case .photo:
            return "jpg"
        case .unknown:
            return "unknown"
        }
    }
    
    var title: String {
        switch self {
        case .video:
            return "Video"
        case .photo:
            return "Photo"
        case .unknown:
            fatalError()
        }
    }
    
    var path: String {
        switch self {
        case .video:
            return "video"
        case .photo:
            return "photo"
        case .unknown:
            fatalError()
        }
    }
    
    var fileDescription: String {
        switch self {
            
        case .video:
            return "video"
        case .photo:
            return "image"
        case .unknown:
            return ""
        }
    }
}

enum CameraMode: Int {
    case photo
    case video
}
