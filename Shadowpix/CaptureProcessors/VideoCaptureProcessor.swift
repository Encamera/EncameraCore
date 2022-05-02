//
//  VideoCaptureProcessor.swift
//  Shadowpix
//
//  Created by Alexander Freas on 18.04.22.
//

import Foundation
import AVFoundation

class VideoCaptureProcessor: NSObject {
    
//    private let captureSettings: AVCapturePhotoSettings
    
    private let completion: () -> (Void)
 
    init(completion: @escaping ()->(Void)) {
        self.completion = completion
    }
    
    deinit {
        
    }
    
}

extension VideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print(outputFileURL)
        completion()
    }
    
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print(fileURL, connections)
    }
    
}
