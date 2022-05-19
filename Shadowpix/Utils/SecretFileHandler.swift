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
    case sourceFileAccessError
}


class SecretFileHandler {
    
    enum SecretFilesError: Error {
        case keyError
        case encryptError
        case decryptError
        case sourceFileAccessError
    }
    
    
    let sourceURL: URL
    let destinationURL: URL
    let key: Array<UInt8>
    
    init(key: Array<UInt8>, sourceURL: URL, destinationURL: URL) {
        self.key = key
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }
    
    private let sodium = Sodium()
    var cancellables = Set<AnyCancellable>()

    private enum Constants {
        static let defaultBlockSize: Int = 1024
    }
    
    
    func encryptFile() -> AnyPublisher<URL, SecretFilesError> {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: key) else {
            print("Could not create stream with key")
            return Fail(error: SecretFilesError.encryptError).eraseToAnyPublisher()
        }
        print("encrypting", key, streamEnc.header())
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
                    }).sink { [weak self] data in
                        guard let self = self else {
                            return
                        }
                        completion(.success(self.destinationURL))
                    } receiveValue: { data in
                        try? destinationFileHandle.write(contentsOf: data)
                    }.store(in: &self.cancellables)
            }.eraseToAnyPublisher()
            
        } catch {
            return Fail(error: SecretFilesError.sourceFileAccessError).eraseToAnyPublisher()
        }
    }
    
    func decryptFile() -> AnyPublisher<URL, SecretFilesError> {
        
        
        do {
            let sourceFileHandle = try FileHandle(forReadingFrom: sourceURL)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let destinationFileHandle = try FileHandle(forWritingTo: destinationURL)
            let headerBytes = try sourceFileHandle.read(upToCount: 24)
            var headerBuffer = [UInt8](repeating: 0, count: 24)
            headerBytes?.copyBytes(to: &headerBuffer, count: 24)
            print("decrypting", key, headerBuffer)
            
            let blockSizeInfo = try sourceFileHandle.read(upToCount: 8)
            let blockSize: UInt32 = blockSizeInfo!.withUnsafeBytes({ $0.load(as: UInt32.self)
            })
            
            
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: key, header: headerBuffer) else {
                print("Could not create stream with key")
                return Fail(error: SecretFilesError.keyError).eraseToAnyPublisher()
            }
            return Future { completion in
                
                ChunkedFileProcessingPublisher(sourceFileHandle: sourceFileHandle, blockSize: Int(blockSize)).map { (bytes, _) -> Data in
                    let (message, _) = streamDec.pull(cipherText: bytes)!
                    return Data(message)
                }.sink { [weak self] signal in
                    guard let self = self else { return }
                    completion(.success(self.destinationURL))
                } receiveValue: { data in
                    try? destinationFileHandle.write(contentsOf: data)
                }.store(in: &self.cancellables)

            }.eraseToAnyPublisher()
        } catch {
            return Fail(error: SecretFilesError.decryptError).eraseToAnyPublisher()
        }
    }
    
    private func chunkedRead(operation: @escaping (Data) -> (Data)) {
        
        
        
    }
    
}
