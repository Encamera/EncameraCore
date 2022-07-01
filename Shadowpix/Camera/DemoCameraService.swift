//
//  DemoCameraService.swift
//  Shadowpix
//
//  Created by Alexander Freas on 27.06.22.
//

import Foundation
import AVFoundation
import Combine

class DemoCameraService: CameraServicable {
    required init(model: CameraServiceModel) {
        
    }
    
    var model: CameraServiceModel = CameraServiceModel(keyManager: MultipleKeyKeychainManager(isAuthorized: Just(true).eraseToAnyPublisher()), fileWriter: DemoFileEnumerator())
    var isLivePhotoEnabled: Bool = false
    func stop() {
        
    }
    
    var flashMode: AVCaptureDevice.FlashMode = .on
    
    var shouldShowAlertView: Bool = false
    
    var shouldShowSpinner: Bool = false
    
    var willCapturePhoto: Bool = false
    
    var isCameraButtonDisabled: Bool = false
    
    var isCameraUnavailable: Bool = false
    
    var isRecordingVideo: Bool = false
    
    var cameraMode: CameraMode = .photo
    
    var scannedKey: ImageKey?
    
    var alertError: AlertError = AlertError()
    
    var fileWriter: FileWriter?
    
    var session: AVCaptureSession = AVCaptureSession()
    
    
    func configure() {
        
    }
    
    func checkForPermissions() {
        
    }
    
    func changeCamera() {
        
    }
    
    func focus(at focusPoint: CGPoint) {
        
    }
    
    func stop(completion: (() -> ())?) {
        
    }
    
    func start() {
        
    }
    
    func set(zoom: CGFloat) {
        
    }
    
    func toggleVideoCapture() {
        
    }
    
    func capturePhoto() {
        
    }
    
    
}
