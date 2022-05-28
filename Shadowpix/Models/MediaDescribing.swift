//
//  MediaMetadata.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

protocol MediaDescribing {
    var mediaType: MediaType { get }
    var sourceURL: URL? { get }
    var data: Data? { get }

}

