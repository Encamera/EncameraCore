//
//  VideoFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.04.22.
//

import Foundation
import Sodium

struct VideoFileProcessor {
    
    enum VideoFilesManagerError: Error {
        case keyError
        case encryptError
        case sourceFileAccessError
    }
    
    
    let sourceURL: URL
    let destinationURL: URL
    let key: Array<UInt8>
    
//    private let header: SecretStream.XChaCha20Poly1305.Header?
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
            
            //close outputFileHandle after reading data complete.
            sourceFileHandle.closeFile()
            completion(destinationURL, nil)
            print("File reading complete")
            
        } catch let error as NSError {
            completion(nil, .encryptError)
            print("Error : \(error.localizedDescription)")
        }

    }
    
    func encryptVideo(completion: @escaping (URL?, VideoFilesManagerError?) -> Void) {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: key) else {
            print("Could not create stream with key")
            completion(nil, .keyError)
            return
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
            chunkedOperation(sourceFileHandle: sourceFileHandle,
                             destinationFileHandle: destinationFileHandle,
                             operation: { (bytes, isFinal) in
                let message = streamEnc.push(message: bytes, tag: isFinal ? .FINAL : .MESSAGE)!
                writeBlockSizeOperation?(message)
                return Data(message)
            }, completion: completion)
        } catch {
            
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
