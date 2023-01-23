//
//  FileOperationBus.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import Foundation
import Combine


enum FileOperation {
    case create(EncryptedMedia)
    case delete(EncryptedMedia)
}


struct FileOperationBus {
    
    static var shared: FileOperationBus = FileOperationBus()
    
    var operations: AnyPublisher<FileOperation, Never> {
        operationSubject.share().eraseToAnyPublisher()
    }
    
    private var operationSubject: PassthroughSubject<FileOperation, Never> = PassthroughSubject()
    
    
    func didCreate(_ media: EncryptedMedia) {
        operationSubject.send(.create(media))
    }
    
    func didDelete(_ media: EncryptedMedia) {
        operationSubject.send(.delete(media))
    }
}
