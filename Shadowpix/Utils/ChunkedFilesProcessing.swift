//
//  Chunked.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine

enum Constants {
    static let defaultBlockSize: Int = 1024
}

class ChunkedFilesProcessingSubscription<S: Subscriber>: Subscription where S.Input == ([UInt8], Bool), S.Failure == Error {
    
 
    enum ChunkedFilesError: Error {
        case sourceFileAccessError
    }
    
    private let sourceFileHandle: FileHandle
    private let blockSize: Int
    private var subscriber: S?
    
    
    init(sourceFileHandle: FileHandle, blockSize: Int, subscriber: S) {
        self.subscriber = subscriber
        self.blockSize = blockSize
        self.sourceFileHandle = sourceFileHandle
    }
    
    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }
            
        do {
            
            guard var data = try sourceFileHandle.read(upToCount: blockSize) else {
                subscriber?.receive(completion: .failure(ChunkedFilesError.sourceFileAccessError))
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

struct ChunkedFileProcessingPublisher: Publisher {
    typealias Output = ([UInt8], Bool)
    typealias Failure = Error
    
    let sourceFileHandle: FileHandle
    let blockSize: Int
    
    init(sourceFileHandle: FileHandle, blockSize: Int = Constants.defaultBlockSize) {
        self.sourceFileHandle = sourceFileHandle
        self.blockSize = blockSize
    }
    
    func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, ([UInt8], Bool) == S.Input {
        let subscription = ChunkedFilesProcessingSubscription(sourceFileHandle: sourceFileHandle, blockSize: blockSize, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }
}
