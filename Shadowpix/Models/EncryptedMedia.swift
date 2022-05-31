//
//  EncryptedMedia.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

class EncryptedMedia: MediaDescribing, ObservableObject {
    typealias MediaSource = URL
    
    var mediaType: MediaType = .unknown
    
    var source: URL
    
    required init(source: URL) {
        self.source = source
        for type in MediaType.allCases.filter({$0 == .unknown}) {
            if source.lastPathComponent.contains(type.fileDescription) {
                mediaType = type
            }
        }
    }
}

extension EncryptedMedia: Identifiable {
    var id: some Hashable {
        return source.hashValue
    }
}
