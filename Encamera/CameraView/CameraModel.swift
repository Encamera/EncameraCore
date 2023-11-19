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

final class CameraModel: NSObject, ObservableObject {
    var service: CameraConfigurationService
    
    var session: AVCaptureSession {
        service.session
    }
    
    @Published var showAlertError = false

    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var isRecordingVideo = false {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = isRecordingVideo
        }
    }
    @Published var recordingDuration: CMTime = .zero
    @Published var willCapturePhoto = false
    @Published var selectedCameraMode: CameraMode = .photo
    @MainActor
    @Published var thumbnailImage: UIImage?
    
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var finalZoomFactor: CGFloat = 1.0
    
    
    // View showing
    @Published var showGalleryView: Bool = false
    @Published var showingAlbum = false
    @Published var showAlertForMissingKey = false
    @Published var showStoreSheet = false
    @Published var showSettingsScreen = false
    
    // Tutorial/info sheets
    @Published var showTookFirstPhotoSheet = false
    @Published var showExplanationForUpgrade = false
    
    @Published var showImportedMediaScreen = false
    @Published var cameraSetupResult: SessionSetupResult = .notDetermined
    var authManager: AuthManager
    var privateKey: PrivateKey
    var albumManager: AlbumManager
    var alertError: AlertError!
    var fileAccess: FileAccess
    var userDefaultsUtil = UserDefaultUtils()
    var purchaseManager: PurchasedPermissionManaging
    private var currentVideoProcessor: AsyncVideoCaptureProcessor?

    
    private var cancellables = Set<AnyCancellable>()
    var isProcessingEvent = false
    let eventSubject = PassthroughSubject<Void, Never>()
    
    init(privateKey: PrivateKey,
         albumManager: AlbumManager,
         authManager: AuthManager,
         cameraService: CameraConfigurationService,
         fileAccess: FileAccess,
         purchaseManager: PurchasedPermissionManaging) {
        
        self.service = cameraService
        self.fileAccess = fileAccess
        self.purchaseManager = purchaseManager
        self.privateKey = privateKey
        self.albumManager = albumManager

        self.authManager = authManager
        super.init()
        self.$selectedCameraMode
            .receive(on: RunLoop.main)
            .sink { newMode in
            Task {
                 await self.service.configureForMode(targetMode: newMode)
            }
        }
        .store(in: &self.cancellables)
        Task {
            let result = await cameraService.model.setupResult
            await MainActor.run {
                self.cameraSetupResult = result
            }
            if let album = albumManager.currentAlbum {
                await self.fileAccess.configure(
                    for: album, with: privateKey, albumManager: albumManager
                )
            }
        }

        eventSubject
            .handleEvents(receiveOutput: { _ in
                if !self.isProcessingEvent {
                    self.isProcessingEvent = true

                    Task {
                        guard authManager.isAuthenticated else {
                            return
                        }
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
                self.eventSubject.send()

            }.store(in: &cancellables)
        FileOperationBus.shared.operations.sink { operation in
            Task {
                await self.loadThumbnail()
            }
        }.store(in: &cancellables)
        albumManager.albumPublisher
            .compactMap({$0})
            .sink { album in
            Task {
                await self.fileAccess.configure(for: album, with: privateKey, albumManager: albumManager)
                await self.loadThumbnail()
            }
        }.store(in: &cancellables)
        setupPublishedVars()
    }
    
    func setupPublishedVars() {
        UserDefaultUtils.publisher(for: .capturedPhotos)
            .compactMap({$0 as? Int})
            .compactMap({ Double($0)})
            .receive(on: DispatchQueue.main)
            .delay(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] value in
                guard let `self` = self else {
                    return
                }
                withAnimation {
                    switch value {
                    case AppConstants.numberOfPhotosBeforeInitialTutorial:
                        self.showTookFirstPhotoSheet = true
                    case AppConstants.maxPhotoCountBeforePurchase:
                        self.showExplanationForUpgrade = !self.purchaseManager.isAllowedAccess(feature: .accessPhoto(count: AppConstants.maxPhotoCountBeforePurchase))
                    default:
                        self.showTookFirstPhotoSheet = false
                        self.showExplanationForUpgrade = false
                    }
                }
            }.store(in: &cancellables)
    }
    
    func loadThumbnail() async {
        
        let media: [EncryptedMedia] = await fileAccess.enumerateMedia()
        guard let firstMedia = media.first else {
            await MainActor.run {
                self.thumbnailImage = nil
            }
            return
        }
        do {
            let cleartextPreview = try await fileAccess.loadMediaPreview(for: firstMedia)
            guard let thumbnail = UIImage(data: cleartextPreview.thumbnailMedia.source) else {
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
    
    func captureButtonPressed() async throws {

        
        switch selectedCameraMode {
        case .photo:
            
            
            let photoProcessor = try await service.createPhotoProcessor(flashMode: flashMode)
            
            let photoObject = try await photoProcessor.takePhoto()
            
            await MainActor.run(body: {
                willCapturePhoto = true
            })
            do {
                if let photo = photoObject.photo {
                    try await fileAccess.save(media: photo) { _ in }
                }
                
                if let livePhoto = photoObject.livePhoto {
                    try await fileAccess.save(media: livePhoto) { _ in }
                }
                UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)

            } catch let filesError as FileAccessError {
                await MainActor.run {
                    switch filesError {
                        
                    
                    case .missingPrivateKey:
                        showAlertForMissingKey = true
                    default:
                        break
                    }
                }
            } catch {
                
            }
            await MainActor.run(body: {
                willCapturePhoto = false
            })
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
            }).store(in: &cancellables)
            let video = try await videoProcessor.takeVideo()
            await MainActor.run(body: {
                isRecordingVideo = false
                setupTorchForVideo()
            })
            currentVideoProcessor = nil
            try await fileAccess.save(media: video) { _ in }
            UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
        }
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
            await service.changeCamera()
        }
    }
    
    func zoom(with factor: CGFloat) {
        Task {
            await service.set(zoom: factor)
        }
    }
    
    func switchFlash() {
        flashMode = flashMode.nextMode
    }
    
    func handleMagnificationOnChanged(scale: CGFloat) {
        currentZoomFactor = scale
        zoom(with: finalZoomFactor * currentZoomFactor)
    }
    
    func handleMagnificationEnded(scale: CGFloat) {
        finalZoomFactor *= currentZoomFactor
        currentZoomFactor = .zero
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
