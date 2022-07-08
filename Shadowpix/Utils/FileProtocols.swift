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

        if FileManager.default.fileExists(atPath: baseURL.path) == false {
            
            do {
                try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("could not create directory \(error.localizedDescription)")
            }
            
        }

    }
    
    func driveURLForNewMedia<T: MediaDescribing>(_ media: T) -> URL {
        let filename = "\(media.id).\(media.mediaType.fileExtension).shdwpic"
        

        return baseURL.appendingPathComponent(filename)
    }
    
    func thumbnailFor<T: MediaDescribing>(media: T) -> EncryptedMedia {
        let thumbnailURL = thumbnailURLForMedia(media)
        let media = EncryptedMedia(source: thumbnailURL, mediaType: .thumbnail, id: media.id)
        return media
    }
    
    func thumbnailURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(media.mediaType.fileExtension).\(MediaType.thumbnail.fileExtension)")
        return thumbnailPath
    }
    
    func previewURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(media.mediaType.fileExtension).\(MediaType.preview.fileExtension)")
        return thumbnailPath
    }
}

protocol FileEnumerator {
        
    init(key: ImageKey)
    func enumerateMedia<T: MediaDescribing>() async -> [T] where T.MediaSource == URL
}

protocol FileReader {
    
    init(key: ImageKey)
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<Data>
}

protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func saveThumbnail<T: MediaDescribing>(data: Data, sourceMedia: T) async throws -> CleartextMedia<Data>
    @discardableResult func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data>
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init(key: ImageKey)
}
