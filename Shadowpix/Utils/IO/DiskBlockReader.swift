//
//  FileBlock.swift
//  Shadowpix
//
//  Created by Alexander Freas on 20.06.22.
//

import Foundation

class DiskBlockReader: FileLikeBlockReader {
    
    
    var source: URL
    private var fileHandle: FileHandle?
    private var mode: BlockIOMode
    
    var size: UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else {
            return 0
        }
        return attributes[FileAttributeKey.size] as! UInt64
    }

    init(source: URL, mode: BlockIOMode) throws {
        self.source = source
        self.mode = mode
        switch mode {
        case .reading:
            fileHandle = try FileHandle(forReadingFrom: source)
        case .writing:
            fileHandle = try? FileHandle(forWritingTo: source)
        }
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


