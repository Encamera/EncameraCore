//
//  CameraService.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import Foundation
import Combine
import AVFoundation
import UIKit
import SwiftUI
import MediaPlayer

//  MARK: Class Camera Service, handles setup of AVFoundation needed for a basic camera app.
struct Photo: Identifiable, Equatable {
//    The ID of the captured photo
    var id: String
//    Data representation of the captured photo
    var originalData: Data
    
    init(id: String = UUID().uuidString, originalData: Data) {
        self.id = id
        self.originalData = originalData
        
        
                          
    }
}

struct AlertError {
    var title: String = ""
    var message: String = ""
    var primaryButtonTitle = "Accept"
    var secondaryButtonTitle: String?
    var primaryAction: (() -> ())?
    var secondaryAction: (() -> ())?
    
    init(title: String = "", message: String = "", primaryButtonTitle: String = "Accept", secondaryButtonTitle: String? = nil, primaryAction: (() -> ())? = nil, secondaryAction: (() -> ())? = nil) {
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryAction = secondaryAction
    }
}

extension Photo {
    var compressedData: Data? {
        ImageResizer(targetWidth: 800).resize(data: originalData)?.jpegData(compressionQuality: 0.5)
    }
    var thumbnailData: Data? {
        ImageResizer(targetWidth: 100).resize(data: originalData)?.jpegData(compressionQuality: 0.5)
    }
    var thumbnailImage: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }
    var image: UIImage? {
        guard let data = compressedData else { return nil }
        return UIImage(data: data)
    }
}



class CameraService {
    typealias PhotoCaptureSessionID = String
    
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var shouldShowAlertView = false
    @Published var shouldShowSpinner = false
    @Published var willCapturePhoto = false
    @Published var isCameraButtonDisabled = true
    @Published var isCameraUnavailable = true
    @Published var isRecordingVideo = false
    @Published var mode: CameraMode = .photo
    @Published var scannedKey: ImageKey?

//    MARK: Alert properties
    var alertError: AlertError = AlertError()
    
// MARK: Session Management Properties
    
    let session = AVCaptureSession()
    var isSessionRunning = false
    var isConfigured = false
    var setupResult: SessionSetupResult = .success
    
    private let sessionQueue = DispatchQueue(label: "session queue")
    private lazy var metadataProcessor = QRCodeCaptureProcessor()
    private var volumeObservation: NSKeyValueObservation?
    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!
    
    // MARK: Device Configuration Properties
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
    
    // MARK: Capturing Photos
    
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    
    private var inProgressPhotoCaptureDelegates = [Int64: PhotoCaptureProcessor]()
    private var inProgressVideoCaptureDelegates = [Int64: VideoCaptureProcessor]()
    // MARK: KVO and Notifications Properties
    
    private var keyValueObservations = [NSKeyValueObservation]()
    private var cancellables = Set<AnyCancellable>()
    private var keyManager: KeyManager
    private var fileWriter: FileWriter
    
    init(keyManager: KeyManager, fileWriter: FileWriter) {
        self.fileWriter = fileWriter
        self.keyManager = keyManager
    }
    
    func configure() {
        /*
         Setup the capture session.
         In general, it's not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Don't perform these tasks on the main queue because
         AVCaptureSession.startRunning() is a blocking call, which can
         take a long time. Dispatch session setup to the sessionQueue, so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        scannedKey = metadataProcessor.lastValidKeyObject
        sessionQueue.async {
            self.initialSessionConfiguration()
        }
        
    }
    
    //        MARK: Checks for user's permisions
    func checkForPermissions() {
      
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. Suspend the session queue to delay session
             setup until the access request has completed.
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access.
            setupResult = .notAuthorized
            
            DispatchQueue.main.async {
                self.alertError = AlertError(title: "Camera Access", message: "Shadowpix doesn't have access to use your camera, please update your privacy settings.", primaryButtonTitle: "Settings", secondaryButtonTitle: nil, primaryAction: {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                  options: [:], completionHandler: nil)
                    
                }, secondaryAction: nil)
                self.shouldShowAlertView = true
                self.isCameraUnavailable = true
                self.isCameraButtonDisabled = true
            }
        }
    }
    
    //  MARK: Session Management
    
    private func configureVolumeButtons() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(true)
        } catch {
            fatalError("Could not configure audio session \(error.localizedDescription)")
        }

        volumeObservation = audioSession.observe(\.outputVolume) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.capturePhoto()
            }
        }
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: .zero)
            volumeView.layer.opacity = 0.0
            UIApplication.shared.keyWindow?.addSubview(volumeView)
        }
    }
    
    // Call this on the session queue.
    /// - Tag: ConfigureSession
    
    private func configureVideoSession() {
        if setupResult != .success {
            return
        }
        
        session.beginConfiguration()
        session.sessionPreset = .hd4K3840x2160
        
    }
    
    private func addPhotoOutputToSession() throws {
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            
            photoOutput.isHighResolutionCaptureEnabled = true
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isLivePhotoCaptureEnabled = true
        } else {
            throw SetupError.couldNotAddPhotoOutputToSession
        }
    }
    
    private func removePhotoOutputFromSession() {
        session.removeOutput(photoOutput)
    }
    
    private func addVideoOutputToSession() throws {
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        } else {
            throw SetupError.couldNotAddVideoInputToSession
        }
    }
    
    private func removeVideoOutputFromSession() {
        session.removeOutput(movieOutput)
    }
    
    private func addMetadataOutputToSession() throws {
        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(metadataProcessor, queue: .main)
            metadataOutput.metadataObjectTypes = metadataProcessor.supportedObjectTypes
        } else {
            throw SetupError.couldNotAddMetadataOutputToSession
        }
    }
    
    private func setupCaptureDevice() throws {
        do {
            var defaultVideoDevice: AVCaptureDevice?
            
            if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                // If a rear dual camera is not available, default to the rear wide angle camera.
                defaultVideoDevice = backCameraDevice
            } else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                // If the rear wide angle camera isn't available, default to the front wide angle camera.
                defaultVideoDevice = frontCameraDevice
            }
            
            guard let videoDevice = defaultVideoDevice else {
                throw SetupError.defaultVideoDeviceUnavailable
            }
            guard let audioDevice = AVCaptureDevice.default(for: .audio),
                      let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice) else {
                throw SetupError.defaultAudioDeviceUnavailable
                }
            session.addInput(audioDeviceInput)
            
            
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                
            } else {
                throw SetupError.couldNotAddVideoInputToSession
            }
        } catch {
            throw SetupError.couldNotCreateVideoDeviceInput(avFoundationError: error)
        }
    }
    
    private func initialSessionConfiguration() {
        if setupResult != .success {
            return
        }
        
        session.beginConfiguration()
        session.sessionPreset = .photo
        configureVolumeButtons()
        do {
            try setupCaptureDevice()
            try addMetadataOutputToSession()
            try addPhotoOutputToSession()
            self.isConfigured = true
        } catch {
            print(error)
            setupResult = .configurationFailed
        }
        session.commitConfiguration()
        
        $mode.dropFirst().sink { [weak self] newMode in
            print(newMode)
            self?.sessionQueue.async {
                do {
                    switch newMode {
                    case .photo:
                        self?.removeVideoOutputFromSession()
                        try self?.addPhotoOutputToSession()
                    case .video:
                        self?.removePhotoOutputFromSession()
                        try self?.addVideoOutputToSession()
                    }
                    
                } catch {
                    print("Could not switch to mode \(newMode)", error)
                    self?.setupResult = .configurationFailed
                }
            }
        }.store(in: &cancellables)

        self.start()
    }
 
    //  MARK: Device Configuration
    
    /// - Tag: ChangeCamera
    func changeCamera() {
        //        MARK: Here disable all camera operation related buttons due to configuration is due upon and must not be interrupted
        DispatchQueue.main.async {
            self.isCameraButtonDisabled = true
        }
        //
        
        sessionQueue.async {
            let currentVideoDevice = self.videoDeviceInput.device
            let currentPosition = currentVideoDevice.position
            
            let preferredPosition: AVCaptureDevice.Position
            let preferredDeviceType: AVCaptureDevice.DeviceType
            
            switch currentPosition {
            case .unspecified, .front:
                preferredPosition = .back
                preferredDeviceType = .builtInWideAngleCamera
                
            case .back:
                preferredPosition = .front
                preferredDeviceType = .builtInWideAngleCamera
                
            @unknown default:
                print("Unknown capture position. Defaulting to back, dual-camera.")
                preferredPosition = .back
                preferredDeviceType = .builtInWideAngleCamera
            }
            let devices = self.videoDeviceDiscoverySession.devices
            var newVideoDevice: AVCaptureDevice? = nil
            
            // First, seek a device with both the preferred position and device type. Otherwise, seek a device with only the preferred position.
            if let device = devices.first(where: { $0.position == preferredPosition && $0.deviceType == preferredDeviceType }) {
                newVideoDevice = device
            } else if let device = devices.first(where: { $0.position == preferredPosition }) {
                newVideoDevice = device
            }
            
            if let videoDevice = newVideoDevice {
                do {
                    let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                    
                    self.session.beginConfiguration()
                    
                    // Remove the existing device input first, because AVCaptureSession doesn't support
                    // simultaneous use of the rear and front cameras.
                    self.session.removeInput(self.videoDeviceInput)
                    if self.session.canAddInput(videoDeviceInput) {
                        self.session.addInput(videoDeviceInput)
                        self.videoDeviceInput = videoDeviceInput
                        
                    } else {
                        self.session.addInput(self.videoDeviceInput)
                    }
                    
                    if let connection = self.photoOutput.connection(with: .video) {
                        if connection.isVideoStabilizationSupported {
                            connection.preferredVideoStabilizationMode = .auto
                        }
                    }
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    self.photoOutput.isLivePhotoCaptureEnabled = true

                    self.session.commitConfiguration()
                } catch {
                    print("Error occurred while creating video device input: \(error)")
                }
            }
            
            DispatchQueue.main.async {
//                MARK: Here enable capture button due to successfull setup
                self.isCameraButtonDisabled = false
            }
        }
    }
    
    func focus(at focusPoint: CGPoint){
        let device = self.videoDeviceInput.device
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = focusPoint
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = .continuousAutoExposure
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            }
        }
        catch {
            print(error.localizedDescription)
        }
    }
    
    /// - Tag: Stop capture session
    
    func stop(completion: (() -> ())? = nil) {
        sessionQueue.async {
            if self.isSessionRunning {
                if self.setupResult == .success {
                    self.session.stopRunning()
                    self.isSessionRunning = self.session.isRunning
                    
                    if !self.session.isRunning {
                        DispatchQueue.main.async {
                            self.isCameraButtonDisabled = true
                            self.isCameraUnavailable = true
                            completion?()
                        }
                    }
                }
            }
        }
    }
    
    /// - Tag: Start capture session
    
    func start() {
//        We use our capture session queue to ensure our UI runs smoothly on the main thread.
        sessionQueue.async {
            if !self.isSessionRunning && self.isConfigured {
                switch self.setupResult {
                case .success:
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                    
                    if self.session.isRunning {
                        DispatchQueue.main.async {
                            self.isCameraButtonDisabled = false
                            self.isCameraUnavailable = false
                        }
                    }
                    
                case .configurationFailed, .notAuthorized:
                    print("Application not authorized to use camera")

                    DispatchQueue.main.async {
                        self.alertError = AlertError(title: "Camera Error", message: "Camera configuration failed. Either your device camera is not available or its missing permissions", primaryButtonTitle: "Accept", secondaryButtonTitle: nil, primaryAction: nil, secondaryAction: nil)
                        self.shouldShowAlertView = true
                        self.isCameraButtonDisabled = true
                        self.isCameraUnavailable = true
                    }
                }
            }
        }
    }
    
    func set(zoom: CGFloat){
        let factor = zoom < 1 ? 1 : zoom
        let device = self.videoDeviceInput.device
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
        catch {
            print(error.localizedDescription)
        }
    }
    
    //    MARK: Capture Photo
    
    private func startCapturingVideo() {
        guard self.setupResult != .configurationFailed, let key = self.keyManager.currentKey else {
            print("Could not start capturing video")
            return
        }
        sessionQueue.async {
            if let photoOutputConnection = self.photoOutput.connection(with: .video) {
                photoOutputConnection.videoOrientation = .portrait
            }
            let videoCaptureProcessor = VideoCaptureProcessor(willCapturePhotoAnimation: {
                
            }, completionHandler: { processor in
                
            }, photoProcessingHandler: { done in
                
            }, fileWriter: self.fileWriter, key: key)
            
            self.inProgressVideoCaptureDelegates[1] = videoCaptureProcessor
            self.movieOutput.startRecording(to: self.fileWriter.createTempURL(for: .video), recordingDelegate: videoCaptureProcessor)
        }
    }
    
    private func stopCapturingVideo() {
        guard self.setupResult != .configurationFailed else {
            return
        }
        sessionQueue.async {
            self.movieOutput.stopRecording()
        }
        

    }
    
    func toggleVideoCapture() {
        if movieOutput.isRecording == true {
            stopCapturingVideo()
        } else {
            startCapturingVideo()
        }
    }
    
    /// - Tag: CapturePhoto
    func capturePhoto() {
        guard self.setupResult != .configurationFailed, let key = self.keyManager.currentKey else {
            print("Could not capture photo")
            return
        }
        self.isCameraButtonDisabled = true
        
        sessionQueue.async {
            if let photoOutputConnection = self.photoOutput.connection(with: .video) {
                photoOutputConnection.videoOrientation = .portrait
            }
            var photoSettings = AVCapturePhotoSettings()
            
            // Capture HEIF photos when supported. Enable according to user settings and high-resolution photos.
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                
            }
            
            // Sets the flash option for this capture.
            if self.videoDeviceInput.device.isFlashAvailable {
                photoSettings.flashMode = self.flashMode
            }
            
            photoSettings.isHighResolutionPhotoEnabled = true
            
            // Sets the preview thumbnail pixel format
            if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
                photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
            }
            
            photoSettings.photoQualityPrioritization = .quality
            
            let photoCaptureProcessor = PhotoCaptureProcessor(with: photoSettings, willCapturePhotoAnimation: { [weak self] in
                // Tells the UI to flash the screen to signal that Shadowpix took a photo.
                DispatchQueue.main.async {
                    self?.willCapturePhoto = true
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.willCapturePhoto = false
                }
                
            }, completionHandler: { [weak self] (photoCaptureProcessor) in
                // When the capture is complete, remove a reference to the photo capture delegate so it can be deallocated.
                guard let photoCaptureProcessor = photoCaptureProcessor as? PhotoCaptureProcessor else {
                    return
                }
                self?.isCameraButtonDisabled = false
                
                self?.sessionQueue.async {
                    self?.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = nil
                }
            }, photoProcessingHandler: { [weak self] animate in
                // Animates a spinner while photo is processing
                if animate {
                    self?.shouldShowSpinner = true
                } else {
                    self?.shouldShowSpinner = false
                }
            }, fileWriter: self.fileWriter, key: key)
            
            // The photo output holds a weak reference to the photo capture delegate and stores it in an array to maintain a strong reference.
            self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = photoCaptureProcessor
            self.photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureProcessor)
        }
    }
}
