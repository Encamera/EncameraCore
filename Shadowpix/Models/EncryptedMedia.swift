//
//  EncryptedMedia.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

struct EncryptedMedia: MediaDescribing {
    var sourceURL: URL?
    var data: Data?
    var mediaType: MediaType = .unknown
    
    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        for type in MediaType.allCases.filter({$0 == .unknown}) {
            if sourceURL.lastPathComponent.contains(type.fileDescription) {
                mediaType = type
            }
        }
    }
}
