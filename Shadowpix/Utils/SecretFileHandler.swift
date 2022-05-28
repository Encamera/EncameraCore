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
    
    
    var sourceMedia: MediaDescribing { get }
    var keyBytes: Array<UInt8> { get }
    var sodium: Sodium { get }
}

extension SecretFileHandler {
    
    var sodium: Sodium {
        Sodium()
    }
    
    func decryptPublisher() -> AnyPublisher<Data, Error> {
        guard let sourceURL = sourceMedia.sourceURL else {
            return Fail(error: SecretFilesError.decryptError)
                .eraseToAnyPublisher()
        }
        do {
            let sourceFileHandle = try FileHandle(forReadingFrom: sourceURL)
            let headerBytes = try sourceFileHandle.read(upToCount: 24)
            var headerBuffer = [UInt8](repeating: 0, count: 24)
            headerBytes?.copyBytes(to: &headerBuffer, count: 24)
            print("decrypting", keyBytes, headerBuffer)
            
            let blockSizeInfo = try sourceFileHandle.read(upToCount: 8)
            let blockSize: UInt32 = blockSizeInfo!.withUnsafeBytes({ $0.load(as: UInt32.self)
            })
            
            
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: headerBuffer) else {
                print("Could not create stream with key")
                return Fail(error: SecretFilesError.keyError).eraseToAnyPublisher()
            }
            return ChunkedFileProcessingPublisher(sourceFileHandle: sourceFileHandle, blockSize: Int(blockSize)).map { (bytes, _) -> Data in
                   let (message, _) = streamDec.pull(cipherText: bytes)!
                   return Data(message)
            }.eraseToAnyPublisher()
        } catch {
            return Fail(error: SecretFilesError.decryptError).eraseToAnyPublisher()
        }
    }
}

class SecretInMemoryFileHander: SecretFileHandler {
    var sourceMedia: MediaDescribing
    
    var keyBytes: Array<UInt8> = []
    
    var cancellables = Set<AnyCancellable>()

    init(sourceMedia: MediaDescribing, keyBytes: Array<UInt8>) {
        self.sourceMedia = sourceMedia
        self.keyBytes = keyBytes
    }
    
    func decryptInMemory() -> AnyPublisher<CleartextMedia, SecretFilesError> {
        
        return Future { completion in
            self.decryptPublisher().reduce(Data()) { accum, next in
                accum + next
            }.sink { complete in
                completion(.failure(SecretFilesError.decryptError))
            } receiveValue: { data in
                let image = CleartextMedia(mediaType: .photo, data: data)
                completion(.success(image))
            }.store(in: &self.cancellables)
        }.eraseToAnyPublisher()
    }
}

class SecretDiskFileHandler: SecretFileHandler {
    
   
    
    let sourceMedia: MediaDescribing
    let destinationURL: URL
    let keyBytes: Array<UInt8>
    
    init(keyBytes: Array<UInt8>, source: MediaDescribing, destinationURL: URL? = nil) {
        self.keyBytes = keyBytes
        self.sourceMedia = source
        self.destinationURL = destinationURL ?? TempFilesManager.createTempURL(media: source)
    }
    
    var cancellables = Set<AnyCancellable>()

    private enum Constants {
        static let defaultBlockSize: Int = 1024
    }
    
    
    func encryptFile() -> AnyPublisher<EncryptedMedia, SecretFilesError> {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            print("Could not create stream with key")
            return Fail(error: SecretFilesError.encryptError)
                .eraseToAnyPublisher()
        }
        
        guard let sourceURL = sourceMedia.sourceURL else {
            print("Could not get sourceURL")
            return Fail(error: SecretFilesError.encryptError)
                .eraseToAnyPublisher()
        }
        print("encrypting", keyBytes, streamEnc.header())
        //open file for reading.
        do {
            let sourceFileHandle = try FileHandle(forReadingFrom: sourceURL)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let destinationFileHandle = try FileHandle(forWritingTo: destinationURL)
            let header = streamEnc.header()
            try destinationFileHandle.write(contentsOf: Data(header))
            var writeBlockSizeOperation: (([UInt8]) -> Void)?
            writeBlockSizeOperation = { cipherText in
                
                let cipherTextLength = withUnsafeBytes(of: cipherText.count) {
                        Array($0)
                    }
                    try! destinationFileHandle.write(contentsOf: Data(cipherTextLength))
                    writeBlockSizeOperation = nil
            }
            return Future { [weak self] completion in
                guard let self = self else {
                    return
                }
                ChunkedFileProcessingPublisher(sourceFileHandle: sourceFileHandle)
                    .map({ (bytes, isFinal)  -> Data in
                        let message = streamEnc.push(message: bytes, tag: isFinal ? .FINAL : .MESSAGE)!
                        writeBlockSizeOperation?(message)
                        return Data(message)
                    }).sink { signal in
                        switch signal {

                        case .finished:
                            let media = EncryptedMedia(sourceURL: self.destinationURL)
                            completion(.success(media))
                        case .failure(_):
                            completion(.failure(SecretFilesError.encryptError))
                        }
                    } receiveValue: { data in
                        try? destinationFileHandle.write(contentsOf: data)
                    }.store(in: &self.cancellables)
            }.eraseToAnyPublisher()
            
        } catch {
            return Fail(error: SecretFilesError.sourceFileAccessError).eraseToAnyPublisher()
        }
    }
    
   
    
    
    func decryptFile() -> AnyPublisher<CleartextMedia, SecretFilesError> {
        
        do {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let destinationFileHandle = try FileHandle(forWritingTo: destinationURL)

            return Future { completion in
                self.decryptPublisher()
                    .sink { recieveCompletion in
                        switch recieveCompletion {
                        case .finished:
                            let media = CleartextMedia(mediaType: .photo, sourceURL: self.destinationURL)
                            completion(.success(media))
                        case .failure(_):
                            completion(.failure(SecretFilesError.decryptError))
                        }
                } receiveValue: { data in
                    do {
                        try destinationFileHandle.write(contentsOf: data)
                    } catch {
                        completion(.failure(SecretFilesError.destinationFileAccessError))
                    }
                }.store(in: &self.cancellables)
            }.eraseToAnyPublisher()
        } catch {
            return Fail(error: SecretFilesError.destinationFileAccessError).eraseToAnyPublisher()
        }
    }
    
    private func chunkedRead(operation: @escaping (Data) -> (Data)) {
        
        
        
    }
    
}
