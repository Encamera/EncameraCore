//
//  CameraModel.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.21.
//

import Foundation
import AVFoundation
import Combine
import UIKit
import MediaPlayer
import SwiftUI
import EncameraCore

extension CameraModel: CameraConfigurationServicableDelegate {
    func didUpdate(zoomLevels: [ZoomLevel]) {
        availableZoomLevels = zoomLevels
    }

    func didUpdate(cameraPosition: AVCaptureDevice.Position) {
        self.cameraPosition = cameraPosition
    }
}

final class CameraModel: NSObject, ObservableObject {

    var service: CameraConfigurationService

    var session: AVCaptureSession {
        service.session
    }

    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var showAlertError = false
    @Published var availableZoomLevels: [ZoomLevel] = []
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var isLivePhotoEnabled = false
    @Published var isRecordingVideo = false {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = isRecordingVideo
        }
    }
    @Published var recordingDuration: CMTime = .zero
    @Published var selectedCameraMode: CameraMode = .photo
    @MainActor
    @Published var thumbnailImage: UIImage?

    @Published var currentZoomFactor: ZoomLevel = .x1 {
        didSet {
            zoom(with: currentZoomFactor)
        }
    }

    // View showing
    @Published var showGalleryView: Bool = false
    @Published var showingAlbum = false
    @Published var showAlertForMissingAlbum = false
    @Published var showStoreSheet = false
    @Published var showSettingsScreen = false

    // Tutorial/info sheets
    @Published var showChooseStorageSheet = false
    @Published var showExplanationForUpgrade = false
    @Published var showSavedToAlbumTooltip = false

    @Published var showImportedMediaScreen = false
    @Published var cameraSetupResult: SessionSetupResult = .notDetermined

    @Published var showPurchaseSheet: Bool = false

    var albumManager: AlbumManaging
    var alertError: AlertError!
    var fileAccess: FileAccess
    var userDefaultsUtil = UserDefaultUtils()
    var purchaseManager: PurchasedPermissionManaging
    var captureActionPublisher: AnyPublisher<Void, Never> {
        captureSubject.eraseToAnyPublisher()
    }
    private var currentVideoProcessor: AsyncVideoCaptureProcessor?
    var closeButtonTapped: (_ targetAlbum: Album?) -> Void


    private var cancellables = Set<AnyCancellable>()
    private var recordingCancellable = Set<AnyCancellable>()
    var isProcessingEvent = false
    let hardwareButtonPressedSubject = PassthroughSubject<Void, Never>()
    let captureSubject = PassthroughSubject<Void, Never>()

    init(albumManager: AlbumManaging,
         cameraService: CameraConfigurationService,
         fileAccess: FileAccess,
         purchaseManager: PurchasedPermissionManaging,
         closeButtonTapped: @escaping (Album?) -> Void) {

        self.service = cameraService
        self.closeButtonTapped = closeButtonTapped
        self.fileAccess = fileAccess
        self.purchaseManager = purchaseManager
        self.albumManager = albumManager

        super.init()
        self.$selectedCameraMode
            .receive(on: RunLoop.main)
            .sink { newMode in
            Task {
                 await self.service.configureForMode(targetMode: newMode)
            }
        }
        .store(in: &self.cancellables)


        albumManager.albumOperationPublisher
            .receive(on: RunLoop.main)
            .sink { operation in
                guard case .selectedAlbumChanged(album: let album) = operation else {
                    return
                }
                Task {
                    guard let album else {
                        return
                    }
                    await self.fileAccess.configure(
                        for: album, albumManager: albumManager
                    )
                }
            }
            .store(in: &cancellables)

        hardwareButtonPressedSubject
            .handleEvents(receiveOutput: { _ in
                if !self.isProcessingEvent {
                    self.isProcessingEvent = true

                    Task {
                        try await self.captureButtonPressed()
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.isProcessingEvent = false
                    }
                }
            })
            .sink { _ in }
            .store(in: &cancellables)

        NotificationUtils.hardwareButtonPressedPublisher
            .sink { _ in
                self.hardwareButtonPressedSubject.send()
            }.store(in: &cancellables)
        FileOperationBus.shared.operations.sink { operation in
            Task {
                await self.loadThumbnail()
            }
        }.store(in: &cancellables)
        setupPublishedVars()
        albumManager.loadAlbumsFromFilesystem()
    }

    func initialConfiguration() async {
        await service.checkForPermissions()
        await service.configure()
        Task {
            let result = await service.model.setupResult
            await MainActor.run {
                self.cameraSetupResult = result
            }
            if let album = albumManager.currentAlbum {
                await self.fileAccess.configure(
                    for: album, albumManager: albumManager
                )
            }
           await service.setDelegate(self)
        }
    }

    func setupPublishedVars() {
        UserDefaultUtils.publisher(for: .capturedPhotos)
            .receive(on: DispatchQueue.main)
            .delay(for: .seconds(0.2), scheduler: RunLoop.main)
            .sink { published in
                let value = Double(published as? Int ?? 0)
                withAnimation {
                    switch value {
                    case let count where count > AppConstants.maxPhotoCountBeforePurchase &&
                        !self.purchaseManager.isAllowedAccess(feature: .accessPhoto(count: count)):
                        self.showExplanationForUpgrade = true
                    default:
                        if let album = self.albumManager.currentAlbum,
                           self.albumManager.albumMediaCount(album: album) == 1 {
                            self.showChooseStorageSheet = true
                        } else {
                            self.showChooseStorageSheet = false
                            self.showExplanationForUpgrade = false
                        }
                    }
                }
            }.store(in: &cancellables)
    }

    func loadThumbnail() async {

        let media: [InteractableMedia<EncryptedMedia>] = await fileAccess.enumerateMedia()
        guard let firstMedia = media.first else {
            await MainActor.run {
                self.thumbnailImage = nil
            }
            return
        }
        do {
            let cleartextPreview = try await fileAccess.loadMediaPreview(for: firstMedia)
            guard let data = cleartextPreview.thumbnailMedia.data, let thumbnail = UIImage(data: data) else {
                await MainActor.run {
                    self.thumbnailImage = nil
                }
                return
            }
            await MainActor.run {
                self.thumbnailImage = thumbnail
            }

        } catch {
            debugPrint("Error loading media preview")
        }
    }

    func stopCamera() async {
        await service.stop(observeRestart: false)
    }

    func captureButtonPressed() async throws {
        switch selectedCameraMode {
        case .photo:

            captureSubject.send()
            let photoProcessor = try await service.createPhotoProcessor(flashMode: flashMode, livePhotoEnabled: isLivePhotoEnabled)

            let photoObject = try await photoProcessor.takePhoto()

            do {
                try await fileAccess.save(media: photoObject) { _ in }
                UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
                UserDefaultUtils.increaseInteger(forKey: .photoAddedCount)
            } catch let filesError as FileAccessError {
                await MainActor.run {
                    switch filesError {
                    case .missingPrivateKey:
                        showAlertForMissingAlbum = true
                    default:
                        break
                    }
                }
            } catch {

            }

        case .video:
            if let currentVideoProcessor = currentVideoProcessor {
                currentVideoProcessor.stop()
                self.currentVideoProcessor = nil
                return
            }
            let videoProcessor = try await service.createVideoProcessor()
            await MainActor.run(body: {
                isRecordingVideo = true
                setupTorchForVideo()
            })
            currentVideoProcessor = videoProcessor
            currentVideoProcessor?.durationPublisher.sink(receiveValue: { value in
                self.recordingDuration = value
            }).store(in: &recordingCancellable)
            let video = try await videoProcessor.takeVideo()
            await MainActor.run(body: {
                isRecordingVideo = false
                setupTorchForVideo()
            })
            currentVideoProcessor = nil
            try await fileAccess.save(media: video) { _ in }
            recordingCancellable.forEach({ $0.cancel()})
            recordingCancellable.removeAll()
            UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
            UserDefaultUtils.increaseInteger(forKey: .videoAddedCount)
        }
        await EventTracking.trackMediaTaken(type: selectedCameraMode)
        await loadThumbnail()
    }



    func setupTorchForVideo() {
        switch flashMode {
        case .off:
            service.toggleTorch(on: false)
        case .on, .auto:
            service.toggleTorch(on: isRecordingVideo)
        @unknown default:
            service.toggleTorch(on: false)
        }
    }

    func flipCamera() {
        Task {
            await service.flipCameraDevice()
        }
    }

    func zoom(with factor: ZoomLevel) {
        Task {
            await service.set(zoom: factor)
        }
    }

    func switchFlash() {
        flashMode = flashMode.nextMode
    }


    func setOrientation(_ orientation: AVCaptureVideoOrientation) {
//        service.model.orientation = orientation
    }
}

private extension AVCaptureDevice.FlashMode {

    var nextMode: AVCaptureDevice.FlashMode {
        switch self {

        case .off:
            return .auto
        case .on:
            return .off
        case .auto:
            return .on
        @unknown default:
            return .off
        }
    }
}
