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
    
    private let sodium = Sodium()
    private let chunkSize = 1024
    
    
    func encryptVideo(completion: @escaping (URL?, VideoFilesManagerError?) -> Void) {
                
        guard let streamEnc = sodium.secretStream.xchacha20poly1305.initPush(secretKey: key) else {
            print("Could not create stream with key")
            completion(nil, .keyError)
            return
        }
        
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            completion(nil, .sourceFileAccessError)
            return
        }
                        
            
        do {
            
            //open file for reading.
            let videoSourceFileHandle = try FileHandle(forReadingFrom: sourceURL)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let encryptedDestinationFileHandle = try FileHandle(forWritingTo: destinationURL)
            
            // get the first chunk
            var data = videoSourceFileHandle.readData(ofLength: chunkSize)
            var byteArray = [UInt8](repeating: 0, count: data.count)
            
            data.copyBytes(to: &byteArray, count: data.count)
            
            while !(data.isEmpty) {
                
                let message = streamEnc.push(message: byteArray)!
                let encryptedData = Data(message)
                try encryptedDestinationFileHandle.write(contentsOf: encryptedData)
                
                
                data = videoSourceFileHandle.readData(ofLength: chunkSize)
                byteArray = [UInt8](repeating: 0, count: data.count)
                data.copyBytes(to: &byteArray, count: data.count)
                
            }
            
            //close outputFileHandle after reading data complete.
            videoSourceFileHandle.closeFile()
            completion(destinationURL, nil)
            print("File reading complete")
            
        } catch let error as NSError {
            completion(nil, .encryptError)
            print("Error : \(error.localizedDescription)")
        }
    }
    
    func decryptVideo(completion: @escaping (URL?, VideoFilesManagerError?) -> Void) {
        
        
        
    }
    
    private func chunkedRead(operation: @escaping (Data) -> (Data)) {
        
        
        
    }
    
}
