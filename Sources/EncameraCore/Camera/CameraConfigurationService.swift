//
//  CameraConfigurationService.swift
//  Encamera
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation
import AVFoundation
import Combine

public enum LivePhotoMode {
    case on
    case off
}

public enum DepthDataDeliveryMode {
    case on
    case off
}

public enum SessionSetupResult {
    case authorized
    case notAuthorized
    case setupComplete
    case configurationFailed
    case notDetermined
}

public enum SetupError: Error {
    case defaultVideoDeviceUnavailable
    case defaultAudioDeviceUnavailable
    case couldNotAddVideoInputToSession
    case couldNotAddAudioInputToSession
    case couldNotCreateVideoDeviceInput(avFoundationError: Error)
    case couldNotAddPhotoOutputToSession
    case couldNotAddVideoOutputToSession
}

public enum MediaProcessorError: Error {
    case missingMovieOutput
    case setupIncomplete
}

public enum CaptureMode: Int {
    case photo = 0
    case movie = 1
}

public enum ZoomLevel: CGFloat {
    case x05 = 0.5
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
    case x5 = 5.0
}

public actor CameraConfigurationService: CameraConfigurationServicable, DebugPrintable {

    public var currentCameraDeviceType: AVCaptureDevice.DeviceType?
    public var currentCameraPosition: AVCaptureDevice.Position = .back {
        didSet {
            Task { @MainActor in
                await delegate?.didUpdate(cameraPosition: currentCameraPosition)
            }
        }
    }
    nonisolated private let canCaptureLivePhotoSubject: CurrentValueSubject<Bool, Never>
    nonisolated public var canCaptureLivePhoto: AnyPublisher<Bool, Never> {
        canCaptureLivePhotoSubject.eraseToAnyPublisher()
    }
    nonisolated public let session = AVCaptureSession()
    private let model: CameraConfigurationServiceModel
    var delegate: CameraConfigurationServicableDelegate?
    private var movieOutput: AVCaptureMovieFileOutput?
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    /// Maps each ZoomLevel to the videoZoomFactor to apply on the current virtual device
    private var zoomFactorMap: [ZoomLevel: CGFloat] = [:] {
        didSet {
            guard Set(zoomFactorMap.keys) != Set(oldValue.keys) else { return }
            let sorted = zoomFactorMap.keys.sorted(by: { $0.rawValue < $1.rawValue })
            Task { @MainActor in
                await delegate?.didUpdate(zoomLevels: sorted)
            }
        }
    }
    private let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
        .builtInUltraWideCamera
    ]
    private var cancellables = Set<AnyCancellable>()

    public init(model: CameraConfigurationServiceModel) {
        self.model = model
        self.canCaptureLivePhotoSubject = CurrentValueSubject(model.canCaptureLivePhoto)
    }

    public func currentSetupResult() -> SessionSetupResult {
        model.setupResult
    }

    public func currentRotationAngle() -> CGFloat {
        model.rotationAngle
    }

    public func configure() async {
        if model.setupResult == .setupComplete {
            printDebug("Starting session from configure()")
            await start()
        } else {
            await self.initialSessionConfiguration()
        }
    }

    public func setDelegate(_ delegate: CameraConfigurationServicableDelegate) async {
        self.delegate = delegate
    }

    public func checkForPermissions() async {

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.model.setupResult = .authorized
        case .notDetermined:

            if await AVCaptureDevice.requestAccess(for: .video) == true {
                self.model.setupResult = .authorized
            } else {
                self.model.setupResult = .notAuthorized
            }

        default:
            model.setupResult = .notAuthorized
        }
    }

    public func stop(observeRestart: Bool) async {
        self.printDebug("Stopping session. ObserveRestart: \(observeRestart)")
        self.stopCancellables()
        if observeRestart {
            NotificationUtils.didBecomeActivePublisher
                .sink { _ in
                    Task {
                        self.printDebug("Starting session from didBecomeActivePublisher")
                        await self.start()
                    }
                }.store(in: &self.cancellables)
            NotificationUtils.willEnterForegroundPublisher
                .sink { _ in
                    Task {
                        self.printDebug("Starting session from willEnterForegroundPublisher")
                        await self.start()
                    }
                }.store(in: &self.cancellables)
        } else {
            cancellables.forEach({ $0.cancel() })
            cancellables.removeAll()
        }

        guard self.session.isRunning, self.model.setupResult == .setupComplete else {
            self.printDebug("Could not stop session, isSessionRunning: \(self.session.isRunning), model.setupResult: \(self.model.setupResult)")
            return
        }

        self.session.stopRunning()

    }

    public func start() async {

        guard !session.isRunning else {
            printDebug("Session is running already")
            return
        }

        NotificationUtils.cameraDidStartRunningPublisher.sink { value in
            Task { @MainActor in
                await self.loadAvailableZoomFactors()
            }
        }.store(in: &cancellables)

        switch model.setupResult {
        case .setupComplete:
            session.startRunning()
            printDebug("Started running session")
            NotificationUtils.didEnterBackgroundPublisher
                .sink { _ in
                    Task {
                        await self.stop(observeRestart: true)
                    }
                }.store(in: &cancellables)
            NotificationUtils.willResignActivePublisher
                .sink { _ in
                    Task {
                        await self.stop(observeRestart: true)
                    }

                }.store(in: &cancellables)
            guard session.isRunning else {
                printDebug("Session is not running")
                return
            }
        default:
            fatalError()
        }
    }

    public func focus(at focusPoint: CGPoint) async {
        guard let device = videoDeviceInput?.device else {
            printDebug("Trying to focus, video device is nil")
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
            printDebug(error.localizedDescription)
        }
    }

    public func setExposureTargetBias(_ bias: Float) async {
        guard let device = videoDeviceInput?.device else {
            printDebug("Trying to set exposure bias, video device is nil")
            return
        }
        do {
            try device.lockForConfiguration()
            let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            printDebug("Failed to set exposure target bias: \(error)")
        }
    }

    public func resetExposureTargetBias() async {
        await setExposureTargetBias(0)
    }

    func loadAvailableZoomFactors() async {
        guard let device = videoDeviceInput?.device else { return }

        let constituents = device.constituentDevices
        let switchOverFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let minZF = device.minAvailableVideoZoomFactor
        let maxZF = device.activeFormat.videoMaxZoomFactor
        let secondaryFactors = device.activeFormat.secondaryNativeResolutionZoomFactors

        printDebug("Zoom discovery: \(device.localizedName) (\(device.deviceType.rawValue)), range: \(minZF)–\(maxZF), switchOvers: \(switchOverFactors)")

        // Step 1: Determine wideBaseZF — the videoZoomFactor where the wide camera is at native 1x.
        // On triple/dualWide cameras, 1.0 = ultra-wide, so wide is at the first switch-over factor.
        // On dual/single cameras, 1.0 = wide already.
        let wideBaseZF: CGFloat
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera:
            wideBaseZF = switchOverFactors.first ?? 1.0
        default:
            wideBaseZF = 1.0
        }
        let hasUltraWide = constituents.contains { $0.deviceType == .builtInUltraWideCamera }
        let hasTelephoto = constituents.contains { $0.deviceType == .builtInTelephotoCamera }
        var teleMarketingZoom: CGFloat?
        if hasTelephoto, let lastSO = switchOverFactors.last {
            teleMarketingZoom = lastSO / wideBaseZF
        }

        let closestTeleLevel = teleMarketingZoom.flatMap { closestZoomLevel(to: $0, from: [.x2, .x3, .x5]) }
        var factorMap: [ZoomLevel: CGFloat] = [:]
        let allLevels: [ZoomLevel] = [.x05, .x1, .x2, .x3, .x5]

        for level in allLevels {
            let videoZF = wideBaseZF * level.rawValue
            let inRange = videoZF >= minZF && videoZF <= maxZF

            let isNative: Bool
            switch level {
            case .x05:
                isNative = hasUltraWide
            case .x1:
                isNative = true
            case .x2, .x3, .x5:
                let hasCenterCrop = secondaryFactors.contains { abs($0 - videoZF) < 0.5 }
                isNative = closestTeleLevel == level || hasCenterCrop
            }

            printDebug("\(level.rawValue)x → videoZF=\(videoZF), inRange=\(inRange), isNative=\(isNative)")

            if inRange && isNative {
                factorMap[level] = videoZF
            }
        }

        printDebug("Available zoom levels: \(factorMap.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.rawValue)x" })")
        self.zoomFactorMap = factorMap
    }

    private func closestZoomLevel(to value: CGFloat, from candidates: [ZoomLevel]) -> ZoomLevel? {
        candidates.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) })
    }

    public func set(rotationAngle: CGFloat) async {
        model.rotationAngle = rotationAngle
    }

    public func set(zoom: ZoomLevel) async {
        guard let device = videoDeviceInput?.device else {
            printDebug("No current camera device available.")
            return
        }
        guard let targetFactor = zoomFactorMap[zoom] else {
            printDebug("Zoom level \(zoom) not available")
            return
        }
        printDebug("Setting zoom \(zoom.rawValue)x → videoZoomFactor=\(targetFactor)")
        do {
            try device.lockForConfiguration()
            let clamped = min(max(targetFactor, device.minAvailableVideoZoomFactor),
                              device.activeFormat.videoMaxZoomFactor)
            if clamped != targetFactor {
                printDebug("Clamped \(targetFactor) to \(clamped) (device range: \(device.minAvailableVideoZoomFactor)–\(device.activeFormat.videoMaxZoomFactor))")
            }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            printDebug("Error occurred while setting video zoom factor: \(error)")
        }
    }

    private func performCameraTransition(to newCamera: AVCaptureDevice) throws {
        let newVideoDeviceInput = try AVCaptureDeviceInput(device: newCamera)

        // Remove the current video device input.
        if let videoDeviceInput = videoDeviceInput {
            session.removeInput(videoDeviceInput)
        }

        // Add the new video device input to the session.
        if session.canAddInput(newVideoDeviceInput) {
            session.addInput(newVideoDeviceInput)
            videoDeviceInput = newVideoDeviceInput
        } else if let videoDeviceInput = videoDeviceInput {
            // Re-add the old input if the new input can't be added.
            session.addInput(videoDeviceInput)
        }

        // Handle video stabilization, etc.
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
    }
    public func flipCameraDevice() async {
        
        guard let currentVideoDevice = self.videoDeviceInput?.device else {
            printDebug("Current video device is nil")
            return
        }
        let currentPosition = currentVideoDevice.position

        let preferredPosition: AVCaptureDevice.Position

        switch currentPosition {
        case .unspecified, .front:
            preferredPosition = .back

        case .back:
            preferredPosition = .front

        @unknown default:
            printDebug("Unknown capture position. Defaulting to back, dual-camera.")
            preferredPosition = .back
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: preferredPosition).devices
        var newVideoDevice: AVCaptureDevice? = nil

        // Prefer virtual devices for the back camera, wide-angle for front.
        let prioritizedTypes: [AVCaptureDevice.DeviceType] = preferredPosition == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]

        for deviceType in prioritizedTypes {
            if let device = devices.first(where: { $0.deviceType == deviceType }) {
                newVideoDevice = device
                break
            }
        }
        if newVideoDevice == nil {
            newVideoDevice = devices.first
        }

        guard let videoDevice = newVideoDevice else {
            printDebug("New video device is nil")
            return
        }

        currentCameraDeviceType = videoDevice.deviceType
        currentCameraPosition = preferredPosition

        do {
            try performCameraTransition(to: videoDevice)
        } catch {
            printDebug("Error occurred while creating video device input: \(error)")
        }
        await loadAvailableZoomFactors()
        await configureForMode(targetMode: model.cameraMode)
    }

    public func configureForMode(targetMode: CameraMode) async {

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        printDebug("Configuring for mode \(targetMode)")
        do {
            switch targetMode {
            case .photo:
                try addPhotoOutputToSession()
            case .video:
                try addVideoOutputToSession()
            }
            model.cameraMode = targetMode
        } catch {
            printDebug("Could not switch to mode \(targetMode)", error)
            self.model.setupResult = .configurationFailed
        }
    }

}

extension CameraConfigurationService {

    public func createVideoProcessor(captureRotationAngle: CGFloat? = nil) async throws -> AsyncVideoCaptureProcessor {
        guard let videoOutput = self.movieOutput else {
            throw MediaProcessorError.missingMovieOutput
        }
        let connection = videoOutput.connection(with: .video)
        let angle = captureRotationAngle ?? model.rotationAngle
        if let connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        return AsyncVideoCaptureProcessor(videoCaptureOutput: videoOutput)
    }


    public func createPhotoProcessor(flashMode: AVCaptureDevice.FlashMode, livePhotoEnabled: Bool, captureRotationAngle: CGFloat? = nil) async throws -> AsyncPhotoCaptureProcessor {
        guard self.model.setupResult != .configurationFailed else {
            printDebug("Could not capture photo")
            throw MediaProcessorError.setupIncomplete
        }

        let angle = captureRotationAngle ?? model.rotationAngle
        if let photoOutputConnection = self.photoOutput.connection(with: .video),
           photoOutputConnection.isVideoRotationAngleSupported(angle) {
            photoOutputConnection.videoRotationAngle = angle
        }
        configurePhotoOutput()

        return AsyncPhotoCaptureProcessor(output: photoOutput, livePhotoEnabled: livePhotoEnabled, flashMode: flashMode)
    }

    public nonisolated func toggleTorch(on: Bool) {
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
                printDebug("Torch could not be used")
            }
        } else {
            printDebug("Torch is not available")
        }
    }

}

private extension CameraConfigurationService {

    //  MARK: Session Management



    /// Add photo output to session
    /// Note: must call commit() to session after this
    private func addPhotoOutputToSession() throws {

        if let movieOutput = movieOutput {
            session.removeOutput(movieOutput)
            self.movieOutput = nil
        }
        session.sessionPreset = .photo
        guard session.canAddOutput(photoOutput) else {
            printDebug("Could not add photooutput to session")
            return
        }
        printDebug("Calling addPhotoOutputToSession")

        session.addOutput(photoOutput)
    }

    private func configurePhotoOutput() {
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isHighResolutionCaptureEnabled = true
        let canCaptureLivePhoto = photoOutput.isLivePhotoCaptureSupported
        printDebug("canCaptureLivePhoto \(canCaptureLivePhoto)")
        model.canCaptureLivePhoto = canCaptureLivePhoto
        canCaptureLivePhotoSubject.send(canCaptureLivePhoto)
        photoOutput.isLivePhotoCaptureEnabled = canCaptureLivePhoto
    }

    private func addVideoOutputToSession() throws {
        printDebug("Calling addVideoOutputToSession")

        let movieOutput = AVCaptureMovieFileOutput()

        guard session.canAddOutput(movieOutput) else {
            throw SetupError.couldNotAddVideoOutputToSession
        }
        session.addOutput(movieOutput)
        session.sessionPreset = .high
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        self.movieOutput = movieOutput
    }

    private func stopCancellables() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    private func setupVideoCaptureDevice() throws {
        session.sessionPreset = .photo

        var defaultVideoDevice: AVCaptureDevice?


        // Try to find a suitable camera among the types
        for cameraType in deviceTypes {
            if let device = AVCaptureDevice.default(cameraType, for: .video, position: currentCameraPosition) {
                defaultVideoDevice = device
                currentCameraDeviceType = cameraType
                break
            }
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
                printDebug("Could not add input to session")
            }
        } catch {
            throw SetupError.couldNotCreateVideoDeviceInput(avFoundationError: error)
        }

    }

    private func setupAudioCaptureDevice() throws {

        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice)else {
            return
        }

        if session.canAddInput(audioDeviceInput) {
            session.addInput(audioDeviceInput)
        }
    }

    private func initialSessionConfiguration() async {
        guard model.setupResult == .authorized else {
            return
        }
        do {
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
            }
            // There is an unhandled case here, where if the video input
            // cannot be added to the session, it fails but does nothing
            try setupVideoCaptureDevice()
            try setupAudioCaptureDevice()
            try addPhotoOutputToSession()
        } catch {
            printDebug(error)
            return
        }
        model.setupResult = .setupComplete

        printDebug("Starting session from initialSessionConfiguration")
        await start()
    }



}
