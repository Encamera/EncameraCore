//
//  SecretFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.04.22.
//

import Foundation
import Sodium
import Combine


enum SecretFilesError: Error {
    case keyError
    case encryptError
    case decryptError
    case sourceFileAccessError
    case destinationFileAccessError
}

protocol SecretFileHandler {
    
    associatedtype SourceMediaType: MediaDescribing
    
    var sourceMedia: SourceMediaType { get }
    var keyBytes: Array<UInt8> { get }
    var sodium: Sodium { get }
}

extension SecretFileHandler {
    
    var sodium: Sodium {
        Sodium()
    }
    
    func decryptPublisher() -> AnyPublisher<Data, Error> {
        
        let fileHandler = FileLikeHandler(media: sourceMedia, blockSize: 1024, mode: .reading)
        
        do {
            
            let headerBytes = try fileHandler.read(upToCount: 24)
            var headerBuffer = [UInt8](repeating: 0, count: 24)
            headerBytes?.copyBytes(to: &headerBuffer, count: 24)
            print("decrypting", keyBytes, headerBuffer)
            
            let blockSizeInfo = try fileHandler.read(upToCount: 8)
            let blockSize: UInt32 = blockSizeInfo!.withUnsafeBytes({ $0.load(as: UInt32.self)
            })
            
            
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: headerBuffer) else {
                print("Could not create stream with key")
                return Fail(error: SecretFilesError.keyError).eraseToAnyPublisher()
            }
            return ChunkedFileProcessingPublisher(sourceFileHandle: fileHandler, blockSize: Int(blockSize)).map { (bytes, _) -> Data in
                   let (message, _) = streamDec.pull(cipherText: bytes)!
                   return Data(message)
            }.eraseToAnyPublisher()
        } catch {
            return Fail(error: SecretFilesError.decryptError).eraseToAnyPublisher()
        }
    }
}

class SecretInMemoryFileHander<T: MediaDescribing>: SecretFileHandler {
    var sourceMedia: T

    var keyBytes: Array<UInt8> = []

    var cancellables = Set<AnyCancellable>()

    init(sourceMedia: T, keyBytes: Array<UInt8>) {
        self.sourceMedia = sourceMedia
        self.keyBytes = keyBytes
    }

    func decryptInMemory() -> AnyPublisher<CleartextMedia<Data>, SecretFilesError> {

        return Future { completion in
            self.decryptPublisher().reduce(Data()) { accum, next in
                accum + next
            }.sink { complete in
                completion(.failure(SecretFilesError.decryptError))
            } receiveValue: { data in
                let image = CleartextMedia(source: data)
                completion(.success(image))
            }.store(in: &self.cancellables)
        }.eraseToAnyPublisher()
    }
}

class SecretDiskFileHandler<T: MediaDescribing>: SecretFileHandler {
    
   
    
    let sourceMedia: T
    let destinationURL: URL
    let keyBytes: Array<UInt8>
    
    init(keyBytes: Array<UInt8>, source: T, destinationURL: URL? = nil) {
        self.keyBytes = keyBytes
        self.sourceMedia = source
        self.destinationURL = destinationURL ?? TempFilesManager.shared.createTempURL(for: source.mediaType)
    }
    
    var cancellables = Set<AnyCancellable>()

    private let defaultBlockSize: Int = 1024
    
    
    func encryptFile() -> AnyPublisher<EncryptedMedia, SecretFilesError> {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            print("Could not create stream with key")
            return Fail(error: SecretFilesError.encryptError)
                .eraseToAnyPublisher()
        }
        let destinationMedia = EncryptedMedia(source: destinationURL, type: .video)
        let destinationHandler = FileLikeHandler(media: destinationMedia, blockSize: 1024, mode: .writing)
        let sourceHandler = FileLikeHandler(media: sourceMedia, blockSize: 1024, mode: .reading)
        do {
            try destinationHandler.prepareIfDoesNotExist()
            let header = streamEnc.header()
            try destinationHandler.write(contentsOf: Data(header))
            var writeBlockSizeOperation: (([UInt8]) -> Void)?
            writeBlockSizeOperation = { cipherText in
                
                let cipherTextLength = withUnsafeBytes(of: cipherText.count) {
                        Array($0)
                    }
                    try! destinationHandler.write(contentsOf: Data(cipherTextLength))
                    writeBlockSizeOperation = nil
            }
            return Future { [weak self] completion in
                guard let self = self else {
                    return
                }
                ChunkedFileProcessingPublisher(sourceFileHandle: sourceHandler)
                    .map({ (bytes, isFinal)  -> Data in
                        let message = streamEnc.push(message: bytes, tag: isFinal ? .FINAL : .MESSAGE)!
                        writeBlockSizeOperation?(message)
                        return Data(message)
                    }).sink { signal in
                        switch signal {

                        case .finished:
                            let media = EncryptedMedia(source: self.destinationURL)
                            completion(.success(media))
                        case .failure(_):
                            completion(.failure(SecretFilesError.encryptError))
                        }
                    } receiveValue: { data in
                        try? destinationHandler.write(contentsOf: data)
                    }.store(in: &self.cancellables)
            }.eraseToAnyPublisher()
            
        } catch {
            return Fail(error: SecretFilesError.sourceFileAccessError).eraseToAnyPublisher()
        }
    }
    
   
    
    
    func decryptFile() -> AnyPublisher<CleartextMedia<URL>, SecretFilesError> {
        
        do {
            let destinationMedia = CleartextMedia(source: self.destinationURL)
            let destinationHandler = FileLikeHandler(media: destinationMedia, blockSize: 1024, mode: .writing)
            try destinationHandler.prepareIfDoesNotExist()
            

            return Future { completion in
                self.decryptPublisher()
                    .sink { recieveCompletion in
                        switch recieveCompletion {
                        case .finished:
                            let media = CleartextMedia(source: self.destinationURL)
                            completion(.success(media))
                        case .failure(_):
                            completion(.failure(SecretFilesError.decryptError))
                        }
                } receiveValue: { data in
                    do {
                        try destinationHandler.write(contentsOf: data)
                    } catch {
                        completion(.failure(SecretFilesError.destinationFileAccessError))
                    }
                }.store(in: &self.cancellables)
            }.eraseToAnyPublisher()
        } catch {
            return Fail(error: SecretFilesError.destinationFileAccessError).eraseToAnyPublisher()
        }
    }
}
