//
//  CleartextMedia.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

struct CleartextMedia<T: MediaSourcing>: MediaDescribing {
    
    typealias MediaSource = T
    
    var source: T
    var mediaType: MediaType = .unknown
    
    
    init(source: T) {
        self.source = source
//        for type in MediaType.allCases.filter({$0 == .unknown}) {
//            if sourceURL.lastPathComponent.contains(type.fileDescription) {
//                mediaType = type
//            }
//        }
    }
}


