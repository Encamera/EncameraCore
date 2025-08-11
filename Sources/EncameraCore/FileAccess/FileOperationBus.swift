//
//  FileOperationBus.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import Foundation
import Combine


public enum FileOperation {
    case create(EncryptedMedia)
    case delete([EncryptedMedia])
    case move(from: [EncryptedMedia], to: Album)
}


public struct FileOperationBus {
    
    public static var shared: FileOperationBus = FileOperationBus()
    
    public var operations: AnyPublisher<FileOperation, Never> {
        operationSubject.share().eraseToAnyPublisher()
    }
    
    private var operationSubject: PassthroughSubject<FileOperation, Never> = PassthroughSubject()

    public func didCreate(_ media: EncryptedMedia) {
        operationSubject.send(.create(media))
    }
    
    public func didDelete(_ media: [EncryptedMedia]) {
        operationSubject.send(.delete(media))
    }
    
    public func didMove(_ media: [EncryptedMedia], to album: Album) {
        operationSubject.send(.move(from: media, to: album))
    }
}
