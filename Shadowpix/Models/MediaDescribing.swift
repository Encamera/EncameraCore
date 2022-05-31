//
//  MediaMetadata.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

protocol MediaReference {
    
}

protocol MediaSourcing: Hashable {
    
}

extension Data: MediaSourcing {
    
}

extension URL: MediaSourcing {
    
}

protocol MediaDescribing {
    
    associatedtype MediaSource: MediaSourcing
        
    var source: MediaSource { get }
    var mediaType: MediaType { get }
    init(source: MediaSource)
}

extension MediaDescribing {
    var id: Int {
        source.hashValue
    }
}
