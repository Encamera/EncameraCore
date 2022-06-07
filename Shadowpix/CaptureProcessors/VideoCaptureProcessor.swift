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
    let videoId = NSUUID().uuidString
 
    required init(willCapturePhotoAnimation: @escaping () -> Void, completionHandler: @escaping (CaptureProcessor) -> Void, photoProcessingHandler: @escaping (Bool) -> Void, fileWriter: FileWriter, key: ImageKey) {
        self.fileHandler = iCloudFilesEnumerator(key: key)
        self.completion = completionHandler
    }
    
}

extension VideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print(outputFileURL)
        let cleartextVideo = CleartextMedia(source: outputFileURL, mediaType: .video, id: videoId)
        fileHandler.save(media: cleartextVideo).sink { result in
            TempFilesManager.shared.deleteItem(at: outputFileURL) // a bit hacky, the temp file is created in CameraService so should be initiated here
            self.completion(self)
        } receiveValue: { media in
            print("Saved video to \(media.source.absoluteString)")
        }.store(in: &cancellables)

        
    }
    
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print(fileURL, connections)
    }
    
}
