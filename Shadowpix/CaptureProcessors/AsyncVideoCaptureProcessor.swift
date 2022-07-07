//
//  AsyncVideoCaptureProcessor.swift
//  Shadowpix
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation
import AVFoundation
import Combine

class AsyncVideoCaptureProcessor: NSObject {
    
    private typealias VideoCaptureProcessorContinuation = CheckedContinuation<CleartextMedia<URL>, Error>
    
    private var continuation: VideoCaptureProcessorContinuation?
    private let captureOutput: AVCaptureMovieFileOutput
    let videoId = NSUUID().uuidString
    let tempFileUrl: URL
    
 
    required init(videoCaptureOutput: AVCaptureMovieFileOutput) {
        self.captureOutput = videoCaptureOutput
        self.tempFileUrl = TempFilesManager.shared.createTempURL(for: .video, id: videoId)
    }
    
    func takeVideo() async throws -> CleartextMedia<URL> {
        return try await withCheckedThrowingContinuation({ (continuation: VideoCaptureProcessorContinuation) in
            self.captureOutput.startRecording(to: tempFileUrl, recordingDelegate: self)
            self.continuation = continuation
        })
    }
    
    func stop() {
        captureOutput.stopRecording()
    }
    
}

extension AsyncVideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print(outputFileURL)
        
        let cleartextVideo = CleartextMedia(source: outputFileURL, mediaType: .video, id: videoId)
        continuation?.resume(returning: cleartextVideo)
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print(fileURL)
    }
    
    
}
