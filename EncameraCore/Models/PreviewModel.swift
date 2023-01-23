//
//  PreviewModel.swift
//  Encamera
//
//  Created by Alexander Freas on 22.08.22.
//

import Foundation
struct PreviewModel: Codable {
    
    var id: String
    
    var thumbnailMedia: CleartextMedia<Data>
    var gridID: String {
        "\(thumbnailMedia.mediaType.fileExtension)_\(thumbnailMedia.id)"
    }
    var videoDuration: String?
    
    init(source: CleartextMedia<Data>) {
        let decoded = try! JSONDecoder().decode(PreviewModel.self, from: source.source)
        self.id = decoded.id
        self.thumbnailMedia = decoded.thumbnailMedia
        self.videoDuration = decoded.videoDuration
    }
    
    init(thumbnailMedia: CleartextMedia<Data>) {
        self.thumbnailMedia = thumbnailMedia
        self.id = thumbnailMedia.id
    }
    
}
