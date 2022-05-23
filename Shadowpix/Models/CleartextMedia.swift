//
//  CleartextMedia.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

struct CleartextMedia: MediaDescribing {
    var mediaType: MediaType
    var sourceURL: URL?
    var data: Data?
}
