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
        return CleartextMedia<Data>(source: Data())
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
    func enumerateMedia<T>(for directory: DirectoryModel) async -> [T] where T : MediaDescribing, T.MediaSource == URL {
         let url = Bundle(for: type(of: self)).url(forResource: "image", withExtension: "jpg")!
        
        return (0...10).map { _ in
            T(source: url)!
        }
        
    }
}

class DemoDirectoryModel: DirectoryModel {
    required init(subdirectory: String = "", keyName: String = "") {
        
    }
    
    let subdirectory = ""
    let keyName = ""
    
    private var tempFileManager = TempFilesManager()
    
    var driveURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(),
                          isDirectory: true)
    }
}
