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

final class CameraModel: ObservableObject {
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
    @Published var showingKeySelection = false
    @Published var showAlertForMissingKey = false
    @Published var showStoreSheet = false
    
    // Tutorial/info sheets
    @Published var showTookFirstPhotoSheet = true
    @Published var showExplanationForUpgrade = false

    var authManager: AuthManager
    var keyManager: KeyManager
    var alertError: AlertError!
    var storageSettingsManager: DataStorageSetting
    var fileAccess: FileAccess
    var userDefaultsUtil = UserDefaultUtils()
    var purchaseManager: PurchasedPermissionManaging
    private var currentVideoProcessor: AsyncVideoCaptureProcessor?

    
    private var cancellables = Set<AnyCancellable>()
    
    init(keyManager: KeyManager,
         authManager: AuthManager,
         cameraService: CameraConfigurationService,
         fileAccess: FileAccess,
         storageSettingsManager: DataStorageSetting,
         purchaseManager: PurchasedPermissionManaging) {
        self.service = cameraService
        self.fileAccess = fileAccess
        self.purchaseManager = purchaseManager
        self.keyManager = keyManager
        
        self.authManager = authManager
        self.storageSettingsManager = storageSettingsManager
        
        self.$selectedCameraMode.sink { newMode in
            Task {
                 await self.service.configureForMode(targetMode: newMode)
            }
        }
        .store(in: &self.cancellables)
        Task {
            await self.fileAccess.configure(
                with: keyManager.currentKey,
                storageSettingsManager: DataStorageUserDefaultsSetting()
            )
        }
        NotificationUtils.hardwareButtonPressedPublisher.sink { _ in
            Task {
                try await self.captureButtonPressed()
            }
        }.store(in: &cancellables)
        FileOperationBus.shared.operations.sink { operation in
            Task {
                await self.loadThumbnail()
            }
        }.store(in: &cancellables)
        keyManager.keyPublisher.sink { key in
            Task {
                await self.fileAccess.configure(with: key, storageSettingsManager: DataStorageUserDefaultsSetting())
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
            .sink { value in
                
                switch value {
                case AppConstants.numberOfPhotosBeforeInitialTutorial:
                    self.showTookFirstPhotoSheet = true
                case AppConstants.maxPhotoCountBeforePurchase:
                    self.showExplanationForUpgrade = true
                default:
                    self.showTookFirstPhotoSheet = false
                    self.showExplanationForUpgrade = false
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
            
            UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
            
            let photoProcessor = await service.createPhotoProcessor(flashMode: flashMode)
            
            let photoObject = try await photoProcessor.takePhoto()
            
            await MainActor.run(body: {
                willCapturePhoto = true
            })
            do {
                if let photo = photoObject.photo {
                    try await fileAccess.save(media: photo)
                }
                
                if let livePhoto = photoObject.livePhoto {
                    try await fileAccess.save(media: livePhoto)
                }
            } catch let filesError as FileAccessError {
                await MainActor.run {
                    switch filesError {
                        
                    case .missingDirectoryModel:
                        break
                    case .missingPrivateKey:
                        showAlertForMissingKey = true
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
            })
            currentVideoProcessor = videoProcessor
            currentVideoProcessor?.durationPublisher.sink(receiveValue: { value in
                self.recordingDuration = value
            }).store(in: &cancellables)
            let video = try await videoProcessor.takeVideo()
            await MainActor.run(body: {
                isRecordingVideo = false
            })
            currentVideoProcessor = nil
            try await fileAccess.save(media: video)
            break
        }
        await loadThumbnail()
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
            service.model.orientation = orientation
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
