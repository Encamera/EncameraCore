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

protocol FileLikeBlockReader  {
    
    func prepareIfDoesNotExist() throws
    func readNextBlock() throws -> Data?
    func closeReader() throws
    func read(upToCount: Int) throws -> Data?
    func write(contentsOf data: Data) throws
}
private let blockSize = 1024

class DiskBlockReader: FileLikeBlockReader {
    var source: URL
    private var fileHandle: FileHandle?
    private var blockSize: Int

    init(source: URL, blockSize: Int) {
        self.source = source
        self.blockSize = blockSize
        fileHandle = try? FileHandle(forReadingFrom: source)
    }
    
    func readNextBlock() throws -> Data? {
        return try read(upToCount: blockSize)
    }
    
    func read(upToCount count: Int) throws -> Data? {
        return try fileHandle?.read(upToCount: count)
    }
    
    func closeReader() throws {
        try fileHandle?.close()
    }
    
    func prepareIfDoesNotExist() throws {
        FileManager.default.createFile(atPath: source.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: source)
    }
    
    func write(contentsOf data: Data) throws {
        try fileHandle?.write(contentsOf: data)
    }
}

class DataBlockReader: FileLikeBlockReader {
    private var source: Data
    private var blockSize: Int
    
    init(source: Data, blockSize: Int) {
        self.source = source
        self.blockSize = blockSize
    }
    
    func readNextBlock() throws -> Data? {
        return try read(upToCount: blockSize)
    }
    
    func read(upToCount count: Int) throws -> Data? {
        let reduced = source.advanced(by: count)
        let block = source.subdata(in: 0..<count)
        source = reduced
        return block
    }
    
    func closeReader() {
        
    }
    
    func prepareIfDoesNotExist() throws {
        source = Data()
    }
    
    func write(contentsOf data: Data) throws {
        source.append(contentsOf: data)
    }
}

class FileLikeHandler<T: MediaDescribing>: FileLikeBlockReader {
    
    private var reader: FileLikeBlockReader
    
    init(media: T, blockSize: Int) {
        switch media.source {
        case let source where source is Data:
            self.reader = DataBlockReader(source: source as! Data, blockSize: blockSize)
        case let source where media.source is URL:
            self.reader = DiskBlockReader(source: source as! URL, blockSize: blockSize)
        default:
            fatalError()
        }
    }
    
    func read(upToCount: Int) throws -> Data? {
        try reader.read(upToCount: upToCount)
    }
    
    func readNextBlock() throws -> Data? {
        try reader.readNextBlock()
    }
    
    func closeReader() throws {
        try reader.closeReader()
    }
    func prepareIfDoesNotExist() throws {
        try reader.prepareIfDoesNotExist()
    }
    
    func write(contentsOf data: Data) throws {
        try reader.write(contentsOf: data)
    }
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
            
        } catch let error as NSError {
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
