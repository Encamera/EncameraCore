//
//  Chunked.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine
import SwiftUI

enum Constants {
    static let defaultBlockSize: Int = 1024
}


class ChunkedFilesProcessingSubscription<S: Subscriber, T: MediaDescribing>: Subscription where S.Input == ([UInt8], Bool), S.Failure == Error {
    
 
    enum ChunkedFilesError: Error {
        case sourceFileAccessError
    }
    
    private let sourceFileHandle: FileLikeHandler<T>
    private let blockSize: Int
    private var subscriber: S?
    
    
    init(sourceFileHandle: FileLikeHandler<T>, blockSize: Int, subscriber: S) {
        self.subscriber = subscriber
        self.blockSize = blockSize
        self.sourceFileHandle = sourceFileHandle
    }
    
    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }
            
        do {
            var data = try sourceFileHandle.read(upToCount: blockSize)!
            var byteArray = [UInt8](repeating: 0, count: data.count)
            
            data.copyBytes(to: &byteArray, count: data.count)
            //optimize var usage in this loop
            while true {
                let final = byteArray.count < blockSize
                subscriber?.receive((byteArray, final))
                guard let nextChunk = try? sourceFileHandle.read(upToCount: blockSize) else {
                    break
                }
                data = nextChunk
                byteArray = [UInt8](repeating: 0, count: data.count)
                data.copyBytes(to: &byteArray, count: data.count)
            }
            try sourceFileHandle.closeReader()
            subscriber?.receive(completion: .finished)
            print("File reading complete")
            
        } catch {
            subscriber?.receive(completion: .failure(error))
        }
    }
    
    func cancel() {
        try? sourceFileHandle.closeReader()
    }
}

struct ChunkedFileProcessingPublisher<T: MediaDescribing>: Publisher {
    typealias Output = ([UInt8], Bool)
    typealias Failure = Error
    
    let sourceFileHandle: FileLikeHandler<T>
    let blockSize: Int
    
    init(sourceFileHandle: FileLikeHandler<T>, blockSize: Int = Constants.defaultBlockSize) {
        self.sourceFileHandle = sourceFileHandle
        self.blockSize = blockSize
    }
    
    func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, ([UInt8], Bool) == S.Input {
        let subscription = ChunkedFilesProcessingSubscription(sourceFileHandle: sourceFileHandle, blockSize: blockSize, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }
}
