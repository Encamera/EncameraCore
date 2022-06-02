//
//  VideoCaptureProcessor.swift
//  Shadowpix
//
//  Created by Alexander Freas on 18.04.22.
//

import Foundation
import AVFoundation
import Combine

class VideoCaptureProcessor: NSObject, CaptureProcessor {
    
    private let fileHandler: iCloudFilesEnumerator
    private var cancellables = Set<AnyCancellable>()
    private let completion: (CaptureProcessor) -> (Void)
 
    required init(willCapturePhotoAnimation: @escaping () -> Void, completionHandler: @escaping (CaptureProcessor) -> Void, photoProcessingHandler: @escaping (Bool) -> Void, fileWriter: FileWriter, key: ImageKey) {
        self.fileHandler = iCloudFilesEnumerator(key: key)
        self.completion = completionHandler
    }
    
}

extension VideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print(outputFileURL)
        let cleartextVideo = CleartextMedia(source: outputFileURL)
        fileHandler.save(media: cleartextVideo).sink { result in
            self.completion(self)
        } receiveValue: { media in
            
        }.store(in: &cancellables)

        
    }
    
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print(fileURL, connections)
    }
    
}
