//
//  VideoFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.04.22.
//

import Foundation
import Sodium
import Combine


enum VideoFilesManagerError: Error {
    case keyError
    case encryptError
    case sourceFileAccessError
}

enum Constants {
    static let defaultBlockSize: Int = 1024
}

class ChunkedProcessingSubscription<S: Subscriber>: Subscription where S.Input == ([UInt8], Bool), S.Failure == Error {
    
    
    
    private let sourceFileHandle: FileHandle
    private let blockSize: Int = Constants.defaultBlockSize
    private var subscriber: S?
    
    init(sourceFileHandle: FileHandle, subscriber: S) {
        self.subscriber = subscriber
        self.sourceFileHandle = sourceFileHandle
    }
    
    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }
            
        do {
            
            guard var data = try sourceFileHandle.read(upToCount: blockSize) else {
                subscriber?.receive(completion: .failure(VideoFilesManagerError.sourceFileAccessError))
                return
            }
            var byteArray = [UInt8](repeating: 0, count: data.count)
            
            data.copyBytes(to: &byteArray, count: data.count)
            //optimize var usage in this loop
            while true {
                let final = byteArray.count < blockSize
                subscriber?.receive((byteArray, final))
                guard let nextChunk = try sourceFileHandle.read(upToCount: blockSize) else {
                    break
                }
                data = nextChunk
                byteArray = [UInt8](repeating: 0, count: data.count)
                data.copyBytes(to: &byteArray, count: data.count)
            }
            sourceFileHandle.closeFile()
            subscriber?.receive(completion: .finished)
            print("File reading complete")
            
        } catch let error as NSError {
            subscriber?.receive(completion: .failure(error))
        }
    }
    
    func cancel() {
        try? sourceFileHandle.close()
    }
}

struct ChunkedProcessingPublisher: Publisher {
    typealias Output = ([UInt8], Bool)
    typealias Failure = Error
    
    let sourceFileHandle: FileHandle
    
    func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, ([UInt8], Bool) == S.Input {
        let subscription = ChunkedProcessingSubscription(sourceFileHandle: sourceFileHandle, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }
}

class VideoFileProcessor {
    
    enum VideoFilesManagerError: Error {
        case keyError
        case encryptError
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
    
    private enum Constants {
        static let defaultBlockSize: Int = 1024
    }
    
    func chunkedOperation(sourceFileHandle: FileHandle,
                          destinationFileHandle: FileHandle,
                          operation: @escaping ([UInt8], Bool) -> Data,
                          blockSize: Int = Constants.defaultBlockSize,
                          completion: @escaping (URL?, VideoFilesManagerError?) -> Void) {
        
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            completion(nil, .sourceFileAccessError)
            return
        }
            
        do {
            
            guard var data = try sourceFileHandle.read(upToCount: blockSize) else {
                completion(nil, .sourceFileAccessError)
                return
            }
            var byteArray = [UInt8](repeating: 0, count: data.count)
            
            data.copyBytes(to: &byteArray, count: data.count)
            //optimize var usage in this loop
            while true {
                let final = byteArray.count < blockSize
                let outputData = operation(byteArray, final)
                try destinationFileHandle.write(contentsOf: outputData)
               
                guard let nextChunk = try sourceFileHandle.read(upToCount: blockSize) else {
                    break
                }
                data = nextChunk
                byteArray = [UInt8](repeating: 0, count: data.count)
                data.copyBytes(to: &byteArray, count: data.count)
                
            }
            sourceFileHandle.closeFile()
            completion(destinationURL, nil)
            print("File reading complete")
            
        } catch let error as NSError {
            completion(nil, .encryptError)
            print("Error : \(error.localizedDescription)")
        }

    }
    var cancellables = Set<AnyCancellable>()
    
    func encryptVideo() -> AnyPublisher<URL, VideoFilesManagerError> {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: key) else {
            print("Could not create stream with key")
            return Fail(error: VideoFilesManagerError.encryptError).eraseToAnyPublisher()
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
                ChunkedProcessingPublisher(sourceFileHandle: sourceFileHandle)
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
            return Fail(error: VideoFilesManagerError.sourceFileAccessError).eraseToAnyPublisher()
        }
    }
    
    func decryptVideo(completion: @escaping (URL?, VideoFilesManagerError?) -> Void) {
        
        
        
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
                completion(nil, .keyError)
                return
            }
            
            chunkedOperation(sourceFileHandle: sourceFileHandle,
                             destinationFileHandle: destinationFileHandle,
                             operation: { (bytes, isFinal) in
                let (message, _) = streamDec.pull(cipherText: bytes)!
                return Data(message)
            },
                             blockSize: Int(blockSize),
                             completion: completion)
        } catch {
            
        }
    }
    
    private func chunkedRead(operation: @escaping (Data) -> (Data)) {
        
        
        
    }
    
}
