//
//  BlockHandling.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.06.22.
//

import Foundation

protocol FileLikeBlockReader  {
    
    func prepareIfDoesNotExist() throws
    func readNextBlock() throws -> Data?
    func closeReader() throws
    func read(upToCount: Int) throws -> Data?
    func write(contentsOf data: Data) throws
}

enum BlockIOMode {
    case reading
    case writing
}

private let blockSize = 1024

class DiskBlockReader: FileLikeBlockReader {
    var source: URL
    private var fileHandle: FileHandle?
    private var blockSize: Int
    private var mode: BlockIOMode

    init(source: URL, blockSize: Int, mode: BlockIOMode) throws {
        self.source = source
        self.blockSize = blockSize
        self.mode = mode
        switch mode {
        case .reading:
            fileHandle = try FileHandle(forReadingFrom: source)
        case .writing:
            fileHandle = try? FileHandle(forWritingTo: source)
        }
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
        
        guard mode == .writing else {
            return
        }
        if FileManager.default.fileExists(atPath: source.path) == false {
            try "".data(using: .utf8)?.write(to: source)
        }
        
        if FileManager.default.fileExists(atPath: source.path) == false {
            FileManager.default.createFile(atPath: source.path, contents: "".data(using: .utf8))
        }
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
        let next = count > source.count ? source.count : count
        if next == 0 {
            return nil
        }
        let reduced = source.advanced(by: next)
        let block = source.subdata(in: 0..<next)
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
    
    init(media: T, blockSize: Int, mode: BlockIOMode) throws {
        switch media.source {
        case let source where source is Data:
            self.reader = DataBlockReader(source: source as! Data, blockSize: blockSize)
        case let source where media.source is URL:
            self.reader = try DiskBlockReader(source: source as! URL, blockSize: blockSize, mode: mode)
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
