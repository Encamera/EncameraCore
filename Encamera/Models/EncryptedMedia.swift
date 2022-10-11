//
//  EncryptedMedia.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation

class EncryptedMedia: MediaDescribing, ObservableObject, Codable, Identifiable {
    typealias MediaSource = URL
    
    var mediaType: MediaType = .unknown
    var id: String
    var source: URL
    lazy var timestamp: Date? = {
        try? FileManager.default.attributesOfItem(atPath: source.absoluteString)[FileAttributeKey.creationDate] as? Date
    }()
    
    required init(source: URL, mediaType: MediaType, id: String) {
        self.source = source
        self.mediaType = mediaType
        self.id = id
    }
    
    convenience init?(source: URL, type: MediaType) {
        self.init(source: source)
        self.mediaType = type
    }
    
    required init?(source: URL) {
        self.source = source
        guard let id = source.deletingPathExtension().lastPathComponent.split(separator: ".").first else {
            return nil
        }
        self.id = String(id)
        self.mediaType = MediaType.typeFromMedia(source: self)
    }
}

extension EncryptedMedia: Hashable {
    static func == (lhs: EncryptedMedia, rhs: EncryptedMedia) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    
}
