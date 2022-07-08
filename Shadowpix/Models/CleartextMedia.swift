//
//  CleartextMedia.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

struct CleartextMedia<T: MediaSourcing>: MediaDescribing, Codable {
    
    typealias MediaSource = T
    
    var source: T
    var mediaType: MediaType = .unknown
    var id: String
    
    init(source: T, mediaType: MediaType, id: String) {
        self.init(source: source)
        self.mediaType = mediaType
        self.id = id
    }
    
    init(source: T) {
        self.source = source
        if let source = source as? URL {
            self.id = source.deletingPathExtension().lastPathComponent
        } else if source is Data {
            self.id = NSUUID().uuidString
        } else {
            fatalError()
        }
        mediaType = MediaType.typeFromMedia(source: self)
    }
    
    func delete() throws {
        if let source = source as? URL {
            try FileManager.default.removeItem(at: source)
        }
    }
}


