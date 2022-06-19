//
//  File.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import UIKit
import Combine

enum DemoError: Error {
    case general
}

class DemoFileEnumerator: FileAccess {
    
    required init(key: ImageKey) {
        
    }
    
    func loadThumbnails<T>(for: DirectoryModel) async -> [T] where T : MediaDescribing, T.MediaSource == Data {
        []
    }
    
    func saveThumbnail(media: CleartextMedia<Data>) async throws -> EncryptedMedia {
        EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
    }
    
    func loadMediaToURL<T>(media: T) async throws -> CleartextMedia<URL> where T : MediaDescribing {
        CleartextMedia(source: URL(fileURLWithPath: ""))
    }
    
    func loadMediaInMemory<T>(media: T) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        CleartextMedia(source: Data())
    }
    
    func save<T>(media: CleartextMedia<T>) async throws -> EncryptedMedia where T : MediaSourcing {
        EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
    }
    
    func loadMediaPreview<T>(for media: T) async -> CleartextMedia<Data> where T : MediaDescribing {
        let url = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        let data = try! Data(contentsOf: url)
        return CleartextMedia<Data>(source: data)
    }
    
    func createTempURL(for mediaType: MediaType, id: String) -> URL {
        return URL(fileURLWithPath: "")
    }
    
    required init(key: ImageKey?) {
        
    }
    
    
    typealias MediaTypeHandling = Data
    
    
    let directoryModel = DemoDirectoryModel()
    
    
    init() {
        
    }
    
    required init(directoryModel: DirectoryModel, key: ImageKey?) {
        
    }

    
    required init(directoryModel: DemoDirectoryModel, key: ImageKey?) {
        
    }
    func enumerateMedia<T>(for: MediaType) async -> [T] where T : MediaDescribing, T.MediaSource == URL {
         let url = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        return (0...10).map { val in
            T(source: url, mediaType: .photo, id: "\(val)")
        }
        
    }
}

class DemoDirectoryModel: DirectoryModel {
    var baseURL: URL
    
    var thumbnailDirectory: URL
    
    required init(keyName: KeyName) {
        self.baseURL = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathExtension("base")
        self.thumbnailDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                      isDirectory: true).appendingPathExtension("thumbs")
    }
    
    convenience init() {
        self.init(keyName: "")
    }
    
    let subdirectory = ""
    let keyName = ""
    
    private var tempFileManager = TempFilesManager()
    
}
