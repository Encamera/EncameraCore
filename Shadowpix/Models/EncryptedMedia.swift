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
    
    convenience init(source: URL, type: MediaType) {
        self.init(source: source)
        self.mediaType = type
    }
    
    required init(source: URL) {
        self.source = source
        self.mediaType = MediaType.typeFromExtension(string: source.pathExtension)
    }
}

extension EncryptedMedia: Identifiable {
    var id: some Hashable {
        return source.hashValue
    }
}
