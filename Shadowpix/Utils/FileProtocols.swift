//
//  FileProtocols.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine

protocol DirectoryModel {
    
    init(subdirectory: String, keyName: String)
    var driveURL: URL { get }
}

extension DirectoryModel {
    func driveURLForNewMedia<T: MediaSourcing>(_ media: CleartextMedia<T>) -> URL {
        let filename = "\(media.id).\(media.mediaType.fileExtension).shdwpic"
        return driveURL.appendingPathComponent(filename)
    }
    
    func thumbnailURLForMedia<T: MediaDescribing>(_ media: T) throws -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let thumbnailDirectory = documentsDirectory.appendingPathComponent("thumbs")
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(MediaType.thumbnail.path)")
        if FileManager.default.fileExists(atPath: thumbnailPath.path) == false {
            try FileManager.default.createDirectory(atPath: thumbnailDirectory.path, withIntermediateDirectories: true)
        }
        return thumbnailPath
    }
}

protocol FileEnumerator {
        
    init(key: ImageKey?)
    
    func enumerateMedia<T: MediaDescribing>(for directory: DirectoryModel) async -> [T] where T.MediaSource == URL
}

protocol FileReader {
    
    init(key: ImageKey?)
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> CleartextMedia<Data> where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T) async throws -> CleartextMedia<Data>
}

protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func saveThumbnail(media: CleartextMedia<Data>) async throws -> EncryptedMedia
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init(key: ImageKey?)
}
