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
    case createThumbnailError
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
        
        
        
        do {
            let fileHandler = try FileLikeHandler(media: sourceMedia, blockSize: 1024, mode: .reading)
            let headerBytes = try fileHandler.read(upToCount: 24)
            var headerBuffer = [UInt8](repeating: 0, count: 24)
            headerBytes?.copyBytes(to: &headerBuffer, count: 24)
            
            let blockSizeInfo = try fileHandler.read(upToCount: 8)
            let blockSize: UInt32 = blockSizeInfo!.withUnsafeBytes({ $0.load(as: UInt32.self)
            })
            
            
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: headerBuffer) else {
                print("Could not create stream with key")
                return Fail(error: SecretFilesError.keyError).eraseToAnyPublisher()
            }
            return ChunkedFileProcessingPublisher(sourceFileHandle: fileHandler, blockSize: Int(blockSize)).tryMap { (bytes, _) -> Data in
                guard let (message, _) = streamDec.pull(cipherText: bytes) else {
                    throw SecretFilesError.decryptError
                }
                   return Data(message)
            }.eraseToAnyPublisher()
        } catch {
            print("Error decrypting \(error)")
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

    func decryptInMemory() async throws -> CleartextMedia<Data>  {

        return try await withCheckedThrowingContinuation { continuation in
            
            self.decryptPublisher().reduce(Data()) { accum, next in
                accum + next
            }.sink { complete in
                switch complete {
                    
                case .finished:
                    break
                case .failure(_):
                    continuation.resume(throwing: SecretFilesError.decryptError)
                }
                
            } receiveValue: { [self] data in
                let image = CleartextMedia(source: data, mediaType: self.sourceMedia.mediaType, id: self.sourceMedia.id)
                continuation.resume(returning: image)
            }.store(in: &self.cancellables)
        }
    }
}

class SecretDiskFileHandler<T: MediaDescribing>: SecretFileHandler {
    
   
    
    let sourceMedia: T
    let destinationURL: URL
    let keyBytes: Array<UInt8>
    
    init(keyBytes: Array<UInt8>, source: T, destinationURL: URL? = nil) {
        self.keyBytes = keyBytes
        self.sourceMedia = source
        self.destinationURL = destinationURL ?? TempFilesManager.shared.createTempURL(for: source.mediaType, id: source.id)
    }
    
    var cancellables = Set<AnyCancellable>()

    private let defaultBlockSize: Int = 1024
    
    
    func encryptFile() async throws -> EncryptedMedia {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            print("Could not create stream with key")
            throw SecretFilesError.encryptError
        }
        guard let destinationMedia = EncryptedMedia(source: destinationURL, type: .video) else {
            throw SecretFilesError.sourceFileAccessError
        }
        do {
            let destinationHandler = try FileLikeHandler(media: destinationMedia, blockSize: 1024, mode: .writing)
            let sourceHandler = try FileLikeHandler(media: sourceMedia, blockSize: 1024, mode: .reading)

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
            return try await withCheckedThrowingContinuation { continuation in
                
                ChunkedFileProcessingPublisher(sourceFileHandle: sourceHandler)
                    .map({ (bytes, isFinal)  -> Data in
                        let message = streamEnc.push(message: bytes, tag: isFinal ? .FINAL : .MESSAGE)!
                        writeBlockSizeOperation?(message)
                        return Data(message)
                    }).sink { signal in
                        switch signal {

                        case .finished:
                            guard let media = EncryptedMedia(source: self.destinationURL) else {
                                continuation.resume(throwing:  SecretFilesError.sourceFileAccessError)
                                return
                            }
                            continuation.resume(returning: media)
                        case .failure(_):
                            continuation.resume(throwing: SecretFilesError.encryptError)
                        }
                    } receiveValue: { data in
                        try? destinationHandler.write(contentsOf: data)
                    }.store(in: &self.cancellables)
            }
            
        } catch {
            print("Error encrypting \(error)")
            throw SecretFilesError.sourceFileAccessError
        }
    }
    
   
    
    
    func decryptFile() async throws -> CleartextMedia<URL> {
        
        do {
            let destinationMedia = CleartextMedia(source: self.destinationURL)
            let destinationHandler = try FileLikeHandler(media: destinationMedia, blockSize: 1024, mode: .writing)
            try destinationHandler.prepareIfDoesNotExist()
            

            return try await withUnsafeThrowingContinuation { continuation in
                
                self.decryptPublisher()
                    .sink { recieveCompletion in
                        switch recieveCompletion {
                        case .finished:
                            let media = CleartextMedia(source: self.destinationURL)
                            continuation.resume(returning: media)
                        case .failure(_):
                            continuation.resume(throwing: SecretFilesError.decryptError)
                        }
                } receiveValue: { data in
                    do {
                        try destinationHandler.write(contentsOf: data)
                    } catch {
                        continuation.resume(throwing: SecretFilesError.destinationFileAccessError)
                    }
                }.store(in: &self.cancellables)
            }
            
        } catch {
            throw SecretFilesError.destinationFileAccessError
        }
    }
}
