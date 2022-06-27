//
//  DemoCameraService.swift
//  Shadowpix
//
//  Created by Alexander Freas on 27.06.22.
//

import Foundation
import AVFoundation

class DemoCameraService: CameraServicable {
    required init(keyManager: KeyManager, model: CameraServiceModel) {
        
    }
    
    var model: CameraServiceModel = CameraServiceModel()
    
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
    
    required init(keyManager: KeyManager) {
        
    }
    
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
