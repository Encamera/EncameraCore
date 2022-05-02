//
//  PhotoCaptureProcessor.swift
//  abseil
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import Foundation
import AVFoundation
import CoreImage

class PhotoCaptureProcessor: NSObject {
    
    lazy var context = CIContext()

    private(set) var requestedPhotoSettings: AVCapturePhotoSettings
    
    private let willCapturePhotoAnimation: () -> Void
    
    private let completionHandler: (PhotoCaptureProcessor) -> Void
    
    private let photoProcessingHandler: (Bool) -> Void
    
//    The actual captured photo's data
    var photoData: Data?
    var photoId: String
    
//    The maximum time lapse before telling UI to show a spinner
    private var maxPhotoProcessingTime: CMTime?
        
//    Init takes multiple closures to be called in each step of the photco capture process
    init(with requestedPhotoSettings: AVCapturePhotoSettings, willCapturePhotoAnimation: @escaping () -> Void, completionHandler: @escaping (PhotoCaptureProcessor) -> Void, photoProcessingHandler: @escaping (Bool) -> Void) {
        photoId = String(describing: NSDate().timeIntervalSince1970)

        if let destinationUrl = try? ShadowPixState.shared.tempFilesManager.createLivePhotoiCloudMovieCaptureUrl(photoId: photoId) {
            requestedPhotoSettings.livePhotoMovieFileURL = destinationUrl
        }
        self.requestedPhotoSettings = requestedPhotoSettings
        self.willCapturePhotoAnimation = willCapturePhotoAnimation
        self.completionHandler = completionHandler
        self.photoProcessingHandler = photoProcessingHandler
    }
}

extension PhotoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        
    }
    
    
    
}

extension PhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    
    
    
    // This extension adopts AVCapturePhotoCaptureDelegate protocol methods.
    
    /// - Tag: WillBeginCapture
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {

        maxPhotoProcessingTime = resolvedSettings.photoProcessingTimeRange.start + resolvedSettings.photoProcessingTimeRange.duration
    }
    
    /// - Tag: WillCapturePhoto
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async {
            self.willCapturePhotoAnimation()
        }
        
        guard let maxPhotoProcessingTime = maxPhotoProcessingTime else {
            return
        }
        
        // Show a spinner if processing time exceeds one second.
        let oneSecond = CMTime(seconds: 2, preferredTimescale: 1)
        if maxPhotoProcessingTime > oneSecond {
            DispatchQueue.main.async {
                self.photoProcessingHandler(true)
            }
        }
    }
    
    /// - Tag: DidFinishProcessingPhoto
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        
        DispatchQueue.main.async {
            self.photoProcessingHandler(false)
        }
        
        if let error = error {
            print("Error capturing photo: \(error)")
        } else {
            photoData = photo.fileDataRepresentation()
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let data = try? Data(contentsOf: outputFileURL) else {
            fatalError("Could not get live photo data from url")
        }
        saveEncryptedToiCloudDrive(data, isLivePhoto: true)
    }
    
    
    
    /// - Tag: DidFinishCapture
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
            DispatchQueue.main.async {
                self.completionHandler(self)
            }
            return
        } else {
            guard let data  = photoData else {
                DispatchQueue.main.async {
                    self.completionHandler(self)
                }
                return
            }
           
            self.saveEncryptedToiCloudDrive(data)
        }
    }
}

extension PhotoCaptureProcessor {

//    private func save
    
    private func saveEncryptedToiCloudDrive(_ photoData: Data, tempUrl: URL? = nil, isLivePhoto: Bool = false) {
        
        iCloudFilesManager.saveEncryptedToiCloudDrive(photoData, photoId: photoId, isLivePhoto: isLivePhoto)
        DispatchQueue.main.async {
            self.completionHandler(self)
        }
        
    }
}
