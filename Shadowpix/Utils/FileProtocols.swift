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

protocol FileEnumerator {
        
    init(key: ImageKey?)
    
    func enumerateMedia<T: MediaDescribing>(for directory: DirectoryModel, completion: ([T]) -> Void) where T.MediaSource == URL
}

protocol FileReader {
    
//    associatedtype MediaTypeHandling: MediaSourcing
    init(key: ImageKey?)
    func loadMediaPreview<T: MediaDescribing>(for media: T) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError>
    func loadMediaToURL<T: MediaDescribing>(media: T) -> AnyPublisher<CleartextMedia<URL>, SecretFilesError>
    func loadMediaInMemory<T: MediaDescribing>(media: T) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError>
}

protocol FileWriter {
        
    func save<T: Hashable>(media: CleartextMedia<T>) -> AnyPublisher<EncryptedMedia, SecretFilesError>
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init(key: ImageKey?)
}
