//
//  CameraConfigurationService.swift
//  Shadowpix
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation
import AVFoundation
import Combine

extension CameraConfigurationService {
    enum LivePhotoMode {
        case on
        case off
    }
    
    enum DepthDataDeliveryMode {
        case on
        case off
    }
    
    enum PortraitEffectsMatteDeliveryMode {
        case on
        case off
    }
    
    enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
        case notDetermined
    }
    
    enum SetupError: Error {
        case defaultVideoDeviceUnavailable
        case defaultAudioDeviceUnavailable
        case couldNotAddVideoInputToSession
        case couldNotCreateVideoDeviceInput(avFoundationError: Error)
        case couldNotAddPhotoOutputToSession
        case couldNotAddMetadataOutputToSession
    }
    
    enum CaptureMode: Int {
        case photo = 0
        case movie = 1
    }
}




actor CameraConfigurationService {
    class CameraConfigurationServiceModel {
        var isLivePhotoEnabled = true
        @Published var cameraMode: CameraMode = .photo
        var flashMode: AVCaptureDevice.FlashMode = .off
        var setupResult: SessionSetupResult = .notDetermined
    }
    let session = AVCaptureSession()
    
    private lazy var metadataProcessor = QRCodeCaptureProcessor()
    private var volumeObservation: NSKeyValueObservation?
    private var videoDeviceInput: AVCaptureDeviceInput?
    
    // MARK: Device Configuration Properties
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
    
    // MARK: Capturing Photos
    
    private var currentCaptureOutput: AVCaptureOutput?
    var model: CameraConfigurationServiceModel
    
    private var cancellables = Set<AnyCancellable>()
    
    init(model: CameraConfigurationServiceModel) {
        self.model = model
        
    }
    
    func configure() {
        model.$cameraMode.dropFirst().sink { mode in
            self.configureForMode(targetMode: mode)
        }.store(in: &cancellables)
        self.initialSessionConfiguration()
    }
    
    func checkForPermissions() async {
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.model.setupResult = .success
        case .notDetermined:
            
            if await AVCaptureDevice.requestAccess(for: .video) == false {
                self.model.setupResult = .notAuthorized
            }
            
        default:
            model.setupResult = .notAuthorized
        }
    }
    
    
    func stop() {
        guard self.session.isRunning, self.model.setupResult == .success else {
            print("Could not stop session, isSessionRunning: \(self.session.isRunning), model.setupResult: \(model.setupResult)")
            return
        }
        self.session.stopRunning()
    }
    
    func start() {
        guard !self.session.isRunning else {
            print("Session is running already or is not configured")
            return
        }
        switch self.model.setupResult {
        case .success:
            self.configureForMode(targetMode: self.model.cameraMode)
            self.session.startRunning()
            guard self.session.isRunning else {
                print("Session is not running")
                return
            }
        default:
            fatalError()
        }
    }
    
    func focus(at focusPoint: CGPoint) {
        guard let device = self.videoDeviceInput?.device else {
            print("Trying to focus, video device is nil")
            return
        }
        do {
            if device.isFocusPointOfInterestSupported {
                try device.lockForConfiguration()
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
    
    
    func set(zoom: CGFloat) {
        guard let device = videoDeviceInput?.device else {
            print("Could not get device for zooming")
            return
        }
        let factor = zoom < 1 ? 1 : zoom
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
        catch {
            print(error.localizedDescription)
        }
    }
    
    func changeCamera() {
        
        guard let currentVideoDevice = self.videoDeviceInput?.device else {
            print("Current video device is nil")
            return
        }
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
        
        guard let videoDevice = newVideoDevice else {
            print("New video device is nil")
            return
        }
        do {
            let newVideoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            
            if let videoDeviceInput = self.videoDeviceInput {
                self.session.removeInput(videoDeviceInput)
            }
            
            if self.session.canAddInput(newVideoDeviceInput) {
                self.session.addInput(newVideoDeviceInput)
                self.videoDeviceInput = newVideoDeviceInput
                
            } else if let videoDeviceInput = self.videoDeviceInput {
                self.session.addInput(videoDeviceInput)
            }
            
            if let connection = self.currentCaptureOutput?.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
            self.configureForMode(targetMode: self.model.cameraMode)
            
        } catch {
            print("Error occurred while creating video device input: \(error)")
        }
        
    }
    
    
}

extension CameraConfigurationService {
    
    func createVideoProcessor() throws -> AsyncVideoCaptureProcessor {
        guard let videoOutput = self.currentCaptureOutput as? AVCaptureMovieFileOutput else {
            fatalError()
        }
        return AsyncVideoCaptureProcessor(videoCaptureOutput: videoOutput)
    }
    
    func createPhotoProcessor() throws -> AsyncPhotoCaptureProcessor {
        guard self.model.setupResult != .configurationFailed else {
            print("Could not capture photo")
            fatalError()
        }
        
        if let photoOutputConnection = self.currentCaptureOutput?.connection(with: .video) {
            photoOutputConnection.videoOrientation = .portrait
        }
        var photoSettings = AVCapturePhotoSettings()
        
        // Capture HEIF photos when supported. Enable according to user settings and high-resolution photos.
        if let photoOutput = self.currentCaptureOutput as? AVCapturePhotoOutput, photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        // Sets the flash option for this capture.
        if let videoDeviceInput = self.videoDeviceInput,
           videoDeviceInput.device.isFlashAvailable {
            photoSettings.flashMode = self.model.flashMode
        }
        
        photoSettings.isHighResolutionPhotoEnabled = true
        guard let photoOutput = self.currentCaptureOutput as? AVCapturePhotoOutput else {
            fatalError()
        }
        
        return AsyncPhotoCaptureProcessor(output: photoOutput, requestedPhotoSettings: photoSettings)
    }
}

private extension CameraConfigurationService {
    
    //  MARK: Session Management
    
    private func configureVolumeButtons() {
        //        let audioSession = AVAudioSession.sharedInstance()
        //        do {
        //            try audioSession.setActive(true)
        //        } catch {
        //            fatalError("Could not configure audio session \(error.localizedDescription)")
        //        }
        //
        //        volumeObservation = audioSession.observe(\.outputVolume) { [weak self] _, _ in
        //            DispatchQueue.main.async {
        //                self?.capturePhoto()
        //            }
        //        }
        //        DispatchQueue.main.async {
        //            let volumeView = MPVolumeView(frame: .zero)
        //            volumeView.layer.opacity = 0.0
        //            UIApplication.shared.keyWindow?.addSubview(volumeView)
        //        }
    }
    
    /// Add photo output to session
    /// Note: must call commit() to session after this
    private func addPhotoOutputToSession() throws {
        print("Calling addPhotoOutputToSession")
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        let photoOutput = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOutput) else {
            return
        }
        session.sessionPreset = .photo
        try swapOutput(with: photoOutput)

        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isHighResolutionCaptureEnabled = true
        photoOutput.isLivePhotoCaptureEnabled = model.isLivePhotoEnabled

        currentCaptureOutput = photoOutput
    }
    
    private func addVideoOutputToSession() throws {
        
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        session.sessionPreset = .hd4K3840x2160
        let movieOutput = AVCaptureMovieFileOutput()
        
        try swapOutput(with: movieOutput)
        
        
        session.commitConfiguration()
        
    }
    
    private func swapOutput(with output: AVCaptureOutput) throws {
        if let currentCaptureOutput = currentCaptureOutput {
            session.removeOutput(currentCaptureOutput)
        }
        guard session.canAddOutput(output) else {
            throw SetupError.couldNotAddVideoInputToSession
        }
        session.addOutput(output)
        currentCaptureOutput = output
    }
    
    
    private func addMetadataOutputToSession() throws {
        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            throw SetupError.couldNotAddMetadataOutputToSession
        }
        session.beginConfiguration()
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(metadataProcessor, queue: .main)
        metadataOutput.metadataObjectTypes = metadataProcessor.supportedObjectTypes
        session.commitConfiguration()
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
//            guard
                let audioDevice = AVCaptureDevice.default(for: .audio)!
                  let audioDeviceInput = try! AVCaptureDeviceInput(device: audioDevice)//, session.canAddInput(audioDeviceInput)
//            else {
//                throw SetupError.defaultAudioDeviceUnavailable
//            }
            
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
        guard model.setupResult == .success else {
            return
        }
        
        
        configureVolumeButtons()
        do {
            try setupCaptureDevice()
            try addMetadataOutputToSession()
        } catch {
            print(error)
            model.setupResult = .configurationFailed
        }
        
        self.start()
    }
    
    private func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        
        if device.hasTorch {
            do {
                try device.lockForConfiguration()
                
                if on == true {
                    device.torchMode = .on
                } else {
                    device.torchMode = .off
                }
                
                device.unlockForConfiguration()
            } catch {
                print("Torch could not be used")
            }
        } else {
            print("Torch is not available")
        }
    }
    
    private func configureForMode(targetMode: CameraMode) {
        do {
            switch targetMode {
            case .photo:
                try self.addPhotoOutputToSession()
            case .video:
                try self.addVideoOutputToSession()
            }
            
        } catch {
            print("Could not switch to mode \(targetMode)", error)
            self.model.setupResult = .configurationFailed
        }
        
    }
    
}
