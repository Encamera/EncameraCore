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
    required init(key: ImageKey?) {
        
    }
    
    func loadMediaPreview<T>(for media: T) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError> where T : MediaDescribing {
        return Just(CleartextMedia(source: Data())).setFailureType(to: SecretFilesError.self).eraseToAnyPublisher()

    }
    
    func loadMedia<T>(media: T) -> AnyPublisher<CleartextMedia<URL>, SecretFilesError> where T : MediaDescribing {
        return Just(CleartextMedia(source: URL(fileURLWithPath: ""))).setFailureType(to: SecretFilesError.self).eraseToAnyPublisher()
    }
    
    func loadMedia<T>(media: T) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError> where T : MediaDescribing {
        return Just(CleartextMedia(source: Data())).setFailureType(to: SecretFilesError.self).eraseToAnyPublisher()

    }
    
    func save<T>(media: CleartextMedia<T>) -> AnyPublisher<EncryptedMedia, SecretFilesError> where T : MediaSourcing {
        fatalError()
    }
    
    
    typealias MediaTypeHandling = Data
    
    
    let directoryModel = DemoDirectoryModel()
    
    
    init() {
        
    }
    
    required init(directoryModel: DirectoryModel, key: ImageKey?) {
        
    }

    
    required init(directoryModel: DemoDirectoryModel, key: ImageKey?) {
        
    }
    
    func enumerateMedia<T: MediaDescribing>(completion: ([T]) -> Void) {
        fatalError()
//        completion((0...10).map { _ in
//            T(source: T.MediaSource())
//        })
        
    }
}

class DemoDirectoryModel: DirectoryModel {
    required init(subdirectory: String = "", keyName: String = "") {
        
    }
    
    let subdirectory = ""
    let keyName = ""
    
    var driveURL: URL {
        URL(fileURLWithPath: "")
    }
}
