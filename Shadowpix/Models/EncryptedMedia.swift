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
    var id: String
    var source: URL
    
    convenience init?(source: URL, type: MediaType) {
        self.init(source: source)
        self.mediaType = type
    }
    
    required init?(source: URL) {
        self.source = source
        guard let id = source.deletingPathExtension().lastPathComponent.split(separator: ".").first?.uppercased() else {
            return nil
        }
        self.id = id
        self.mediaType = MediaType.typeFromMedia(source: self)
    }
}
