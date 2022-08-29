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

final class CameraModel: ObservableObject {
    var service: CameraConfigurationService
    
    var session: AVCaptureSession {
        service.session
    }
    
    @Published var showAlertError = false

    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var isRecordingVideo = false
    @Published var recordingDuration: CMTime = .zero
    @Published var willCapturePhoto = false
    @Published var selectedCameraMode: CameraMode = .photo
    @MainActor
    @Published var thumbnailImage: UIImage?
    @Published var showGalleryView: Bool = false
    @Published var showingKeySelection = false
    var authManager: AuthManager
    var keyManager: KeyManager
    var alertError: AlertError!
    var storageSettingsManager: DataStorageSetting
    var fileAccess: FileAccess?
    
    
    private var cancellables = Set<AnyCancellable>()
    
    init(keyManager: KeyManager,
         authManager: AuthManager,
         cameraService: CameraConfigurationService,
         storageSettingsManager: DataStorageSetting) {
        self.service = cameraService
        
        
        self.keyManager = keyManager
        
        self.authManager = authManager
        self.storageSettingsManager = storageSettingsManager
        
        self.$selectedCameraMode.sink { newMode in
            Task {
                 await self.service.configureForMode(targetMode: newMode)
            }
        }
        .store(in: &self.cancellables)
        if let key = keyManager.currentKey {
            self.fileAccess = DiskFileAccess(key: key, storageSettingsManager: DataStorageUserDefaultsSetting())
        }
        keyManager.keyPublisher.sink { key in
            guard let key = key else {
                return
            }
            Task {
                self.fileAccess = DiskFileAccess(key: key, storageSettingsManager: DataStorageUserDefaultsSetting())
                await self.loadThumbnail()
            }
        }.store(in: &cancellables)
    }
    
    func loadThumbnail() async {
        guard let fileAccess = fileAccess else {
            return
        }
        
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
        guard let fileAccess = fileAccess else {
            return
        }
        switch selectedCameraMode {
        case .photo:
            let photoProcessor = try await service.createPhotoProcessor(flashMode: flashMode)
            let photoObject = try await photoProcessor.takePhoto()
            await MainActor.run(body: {
                willCapturePhoto = true
            })
            if let photo = photoObject.photo {
                try await fileAccess.save(media: photo)
            }
            
            if let livePhoto = photoObject.livePhoto {
                try await fileAccess.save(media: livePhoto)
            }
            await MainActor.run(body: {
                willCapturePhoto = false
            })
        case .video:
//            if let currentVideoProcessor = currentVideoProcessor {
//                currentVideoProcessor.stop()
//                self.currentVideoProcessor = nil
//                return
//            }
//            let videoProcessor = try await service.createVideoProcessor()
//            await MainActor.run(body: {
//                isRecordingVideo = true
//            })
//            currentVideoProcessor = videoProcessor
//            currentVideoProcessor?.durationPublisher.sink(receiveValue: { value in
//                self.recordingDuration = value
//            }).store(in: &cancellables)
//            let video = try await videoProcessor.takeVideo()
//            await MainActor.run(body: {
//                isRecordingVideo = false
//            })
//            currentVideoProcessor = nil
//            try await fileAccess.save(media: video)
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
