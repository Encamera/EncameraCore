//
//  FileProtocols.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine

protocol DirectoryModel { // please rename this, not representative of what it does
    var baseURL: URL { get }
    var keyName: KeyName { get }
    var thumbnailDirectory: URL { get }
 
    init(keyName: KeyName)
    func initializeDirectories() throws
}

extension DirectoryModel {
    
    func initializeDirectories() throws {
        if FileManager.default.fileExists(atPath: thumbnailDirectory.path) == false {
            try FileManager.default.createDirectory(atPath: thumbnailDirectory.path, withIntermediateDirectories: true)
        }

        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("could not create directory \(error.localizedDescription)")
        }

    }
    
    func pathContainingMediaOf(type: MediaType) -> URL {
        return baseURL.appendingPathComponent(type.path)
    }
    
    func driveURLForNewMedia<T: MediaSourcing>(_ media: CleartextMedia<T>) -> URL {
        let filename = "\(media.id).\(media.mediaType.fileExtension).shdwpic"
        return baseURL.appendingPathComponent(media.mediaType.path).appendingPathComponent(filename)
    }
    
    func thumbnailFor<T: MediaDescribing>(media: T) throws -> EncryptedMedia {
        let thumbnailURL = try thumbnailURLForMedia(media)
        let media = EncryptedMedia(source: thumbnailURL, mediaType: .thumbnail, id: media.id)
        return media
    }
    
    func thumbnailURLForMedia<T: MediaDescribing>(_ media: T) throws -> URL {
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(MediaType.thumbnail.path)")
        return thumbnailPath
    }
}

protocol FileEnumerator {
        
    init(key: ImageKey)
    
    func enumerateMedia<T: MediaDescribing>(for type: MediaType) async -> [T] where T.MediaSource == URL
//    func loadThumbnails(for type: MediaType) async throws -> [CleartextMedia<Data>]
}

protocol FileReader {
    
    init(key: ImageKey)
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> CleartextMedia<Data> where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T) async throws -> CleartextMedia<Data>
}

protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func saveThumbnail(media: CleartextMedia<Data>) async throws -> EncryptedMedia
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init(key: ImageKey)
}
