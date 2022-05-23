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
    var mediaType: MediaType
}
