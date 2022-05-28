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
