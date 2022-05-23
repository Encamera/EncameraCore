//
//  File.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import UIKit
import Combine



class DemoFileEnumerator: FileAccess {
    func loadMedia(media: MediaDescribing) -> AnyPublisher<CleartextMedia, Never> {
        return Just(CleartextMedia(mediaType: .photo)).eraseToAnyPublisher()
    }
    
    func save(media: CleartextMedia) -> AnyPublisher<EncryptedMedia, Error> {
        return Just(EncryptedMedia(sourceURL: nil, data: nil, mediaType: .video)).setFailureType(to: Error.self).eraseToAnyPublisher()

    }
    
    
    let directoryModel = DemoDirectoryModel()
    
    
    init() {
        
    }
    
    required init(directoryModel: DirectoryModel, key: ImageKey?) {
        
    }
    
    
    func loadMediaPreview(for media: ShadowPixMedia) {
        media.decryptedImage = DecryptedImage(data: UIImage(systemName: "photo.fill")!.pngData()!)
    }
    
    required init(directoryModel: DemoDirectoryModel, key: ImageKey?) {
        
    }
    
    func save(media: CleartextMedia) -> AnyPublisher<ShadowPixMedia, Error> {
        return Just(ShadowPixMedia(url: URL(fileURLWithPath: ""))).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    
    func enumerateMedia(completion: ([ShadowPixMedia]) -> Void) {
        completion((0...10).map { _ in
            ShadowPixMedia(url: URL(fileURLWithPath: ""))
        })
        
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
