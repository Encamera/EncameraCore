//
//  Enums.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.05.22.
//

import Foundation
enum MediaType: Int, CaseIterable {
    
    case photo
    case video
    case thumbnail
    case unknown
    
    static var displayCases: [MediaType] {
        self.allCases.filter({$0 != .unknown && $0 != .thumbnail})
    }
    
    static func typeFromMedia<T: MediaDescribing>(source: T) -> MediaType {
        
        switch source {
        case let media as CleartextMedia<Data>:
            return typeFrom(media: media)
        case let media as CleartextMedia<URL>:
            return typeFrom(media: media)
        case let media as EncryptedMedia:
            return typeFrom(media: media)
        
        default:
            return .unknown
        }
        
    }
    
    private static func typeFrom(media: EncryptedMedia) -> MediaType {
        
        let trimmed = media.source.deletingPathExtension()
        return typeFromURL(trimmed)
    }
    
    private static func typeFrom(media: CleartextMedia<URL>) -> MediaType {
        return typeFromURL(media.source)
    }
    
    private static func typeFromURL(_ url: URL) -> MediaType {
        let fileExtension = url.pathExtension
        guard let type = self.allCases.filter({$0.fileExtension == fileExtension}).first else {
            return .unknown
        }
        return type
    }
    
    private static func typeFrom(media: CleartextMedia<Data>) -> MediaType {
        return .photo
    }
    
    var fileExtension: String {
        switch self {
        case .video:
            return "mov"
        case .photo:
            return "jpg"
        case .unknown:
            return "unknown"
        case .thumbnail:
            return "thmb"
        }
    }
    
    var title: String {
        switch self {
        case .video:
            return "Video"
        case .photo:
            return "Photo"
        case .unknown:
            return "Unknown"
        case .thumbnail:
            return "Thumbnail"
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
        case .thumbnail:
            return "thumbnail"
        }
    }
}

enum CameraMode: Int {
    case photo
    case video
}
