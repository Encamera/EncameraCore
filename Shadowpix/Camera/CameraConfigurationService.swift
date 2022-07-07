//
//  CameraConfigurationService.swift
//  Shadowpix
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation
import AVFoundation
import Combine

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
        case couldNotAddAudioInputToSession
        case couldNotCreateVideoDeviceInput(avFoundationError: Error)
        case couldNotAddPhotoOutputToSession
        case couldNotAddVideoOutputToSession
        case couldNotAddMetadataOutputToSession
    }
    
    enum CaptureMode: Int {
        case photo = 0
        case movie = 1
    }


protocol CameraConfigurationServicable {
    var session: AVCaptureSession { get }
    var model: CameraConfigurationServiceModel { get }
    init(model: CameraConfigurationServiceModel)
    func configure() async
    func checkForPermissions() async
    func stop() async
    func start() async
    func focus(at focusPoint: CGPoint) async
    func set(zoom: CGFloat) async
    func changeCamera() async
    func configureForMode(targetMode: CameraMode) async
}


class CameraConfigurationServiceModel {
    var alertError: AlertError = AlertError()
    @Published var cameraMode: CameraMode = .photo
    var flashMode: AVCaptureDevice.FlashMode = .off
    var setupResult: SessionSetupResult = .notDetermined
}

actor CameraConfigurationService: CameraConfigurationServicable {
    
    let session = AVCaptureSession()
    let model: CameraConfigurationServiceModel

    private lazy var metadataProcessor = QRCodeCaptureProcessor()
    private var movieOutput: AVCaptureMovieFileOutput?
    private let photoOutput = AVCapturePhotoOutput()
    private var volumeObservation: NSKeyValueObservation?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
    private var cancellables = Set<AnyCancellable>()
    
    init(model: CameraConfigurationServiceModel) {
        self.model = model
        
    }
    
    func configure() async {
        await self.initialSessionConfiguration()
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
    
    
    func stop() async {
        guard self.session.isRunning, self.model.setupResult == .success else {
            print("Could not stop session, isSessionRunning: \(self.session.isRunning), model.setupResult: \(model.setupResult)")
            return
        }
        self.session.stopRunning()
    }
    
    func start() async {
        guard !self.session.isRunning else {
            print("Session is running already or is not configured")
            return
        }
        switch self.model.setupResult {
        case .success:
            self.session.startRunning()
            guard self.session.isRunning else {
                print("Session is not running")
                return
            }
        default:
            fatalError()
        }
    }
    
    func focus(at focusPoint: CGPoint) async {
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
    
    
    func set(zoom: CGFloat) async {
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
    
    func changeCamera() async {
        
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
            
            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        } catch {
            print("Error occurred while creating video device input: \(error)")
        }
        
    }
    
    func configureForMode(targetMode: CameraMode) async {
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

extension CameraConfigurationService {
    
    func createVideoProcessor() throws -> AsyncVideoCaptureProcessor {
        guard let videoOutput = self.movieOutput else {
            fatalError()
        }
        return AsyncVideoCaptureProcessor(videoCaptureOutput: videoOutput)
    }
    
    func createPhotoProcessor() throws -> AsyncPhotoCaptureProcessor {
        guard self.model.setupResult != .configurationFailed else {
            print("Could not capture photo")
            fatalError()
        }
        
        if let photoOutputConnection = self.photoOutput.connection(with: .video) {
            photoOutputConnection.videoOrientation = .portrait
        }
        var photoSettings = AVCapturePhotoSettings()
        
        // Capture HEIF photos when supported. Enable according to user settings and high-resolution photos.
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        // Sets the flash option for this capture.
        if let videoDeviceInput = self.videoDeviceInput,
           videoDeviceInput.device.isFlashAvailable {
            photoSettings.flashMode = self.model.flashMode
        }
        
        photoSettings.isHighResolutionPhotoEnabled = true
        
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
        
        guard session.canAddOutput(photoOutput) else {
            return
        }
        if let movieOutput = movieOutput {
            session.removeOutput(movieOutput)
        }
        session.sessionPreset = .photo
        session.addOutput(photoOutput)
        photoOutput.isLivePhotoCaptureEnabled = false
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isHighResolutionCaptureEnabled = true
    }
    
    private func addVideoOutputToSession() throws {
        print("Calling addVideoOutputToSession")

        let movieOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(movieOutput) else {
            throw SetupError.couldNotAddVideoOutputToSession
        }
        session.beginConfiguration()
        session.addOutput(movieOutput)
        session.sessionPreset = .high
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        self.movieOutput = movieOutput
        session.commitConfiguration()
    }
    
    private func addMetadataOutputToSession() throws {
        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            throw SetupError.couldNotAddMetadataOutputToSession
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(metadataProcessor, queue: .main)
        metadataOutput.metadataObjectTypes = metadataProcessor.supportedObjectTypes
    }
    
    private func setupCaptureDevice() throws {
        session.sessionPreset = .photo
        
        var defaultVideoDevice: AVCaptureDevice?
        
        if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            defaultVideoDevice = dualCameraDevice
        } else if let dualWideCameraDevice = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
            // If a rear dual camera is not available, default to the rear dual wide camera.
            defaultVideoDevice = dualWideCameraDevice
        } else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            // If a rear dual wide camera is not available, default to the rear wide angle camera.
            defaultVideoDevice = backCameraDevice
        } else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            // If the rear wide angle camera isn't available, default to the front wide angle camera.
            defaultVideoDevice = frontCameraDevice
        }
        
        
        guard let videoDevice = defaultVideoDevice else {
            throw SetupError.defaultVideoDeviceUnavailable
        }
        
        do {
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
        
        
        
        
        do {
            let audioDevice = AVCaptureDevice.default(for: .audio)!
            let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioDeviceInput) {
                session.addInput(audioDeviceInput)
            } else {
                throw SetupError.couldNotAddAudioInputToSession
            }
            
        } catch {
            throw error
        }
        
    }
    
    private func initialSessionConfiguration() async {
        guard model.setupResult == .success else {
            return
        }
        session.beginConfiguration()
        configureVolumeButtons()
        do {
            try setupCaptureDevice()
//            try addMetadataOutputToSession()
            await configureForMode(targetMode: .photo)
        } catch {
            print(error)
            model.setupResult = .configurationFailed
        }
        session.commitConfiguration()
        await self.start()
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
    
    
}
