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
        
    init(directoryModel: DirectoryModel, key: ImageKey?)
    
    func enumerateMedia(completion: ([ShadowPixMedia]) -> Void)
}

protocol FileReader {
    func loadMediaPreview(for media: ShadowPixMedia)
    func loadMedia(media: MediaDescribing) -> AnyPublisher<CleartextMedia, Never>
}

protocol FileWriter {
    func save(media: CleartextMedia) -> AnyPublisher<EncryptedMedia, Error>
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    
}
