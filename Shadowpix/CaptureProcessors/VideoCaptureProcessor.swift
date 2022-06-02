//
//  VideoCaptureProcessor.swift
//  Shadowpix
//
//  Created by Alexander Freas on 18.04.22.
//

import Foundation
import AVFoundation
import Combine

class VideoCaptureProcessor: NSObject {
    
//    private let captureSettings: AVCapturePhotoSettings
    private let fileHandler: iCloudFilesEnumerator
    private var cancellables = Set<AnyCancellable>()
    private let completion: () -> (Void)
 
    init(key: ImageKey, completion: @escaping ()->(Void)) {
        let directory = iCloudFilesDirectoryModel(subdirectory: MediaType.video.path, keyName: key.name)
        self.fileHandler = iCloudFilesEnumerator(directoryModel: directory, key: key)
        self.completion = completion
    }
    
}

extension VideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print(outputFileURL)
        let cleartextVideo = CleartextMedia(source: outputFileURL)
        fileHandler.save(media: cleartextVideo).sink { result in
            self.completion()
        } receiveValue: { media in
            
        }.store(in: &cancellables)

        
    }
    
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print(fileURL, connections)
    }
    
}
