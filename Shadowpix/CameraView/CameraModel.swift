//
//  CameraModel.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.11.21.
//

import Foundation
import AVFoundation
import Combine
import UIKit

final class CameraModel: ObservableObject {
    private var service: CameraServicable
    
    var session: AVCaptureSession {
        service.session
    }
    
    @Published var showAlertError = false
    
    @Published var isFlashOn = false
    @Published var isRecordingVideo = false
    @Published var willCapturePhoto = false
    @Published var showCameraView = true
    @Published var isLivePhotoEnabled = true
    @Published var selectedCameraMode: CameraMode = .photo
    @Published var thumbnailImage: UIImage?
    @Published var showGalleryView: Bool = false
    @Published var showingKeySelection = false
    var authManager: AuthManager
    var keyManager: KeyManager
    var alertError: AlertError!
    private var fileReader: FileReader & FileEnumerator
    
    
    private var cancellables = Set<AnyCancellable>()
    
    init(keyManager: KeyManager, authManager: AuthManager, cameraService: CameraServicable, fileReader: FileReader & FileEnumerator) {
        self.service = cameraService
        self.keyManager = keyManager
        self.fileReader = fileReader
        self.authManager = authManager

        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                self.showCameraView = false
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                self.showCameraView = true
                self.service.start()
            }.store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .sink { _ in
                self.service.stop()
                self.showCameraView = false
            }.store(in: &cancellables)
            
        service.model.$shouldShowAlertView.sink { [weak self] (val) in
            self?.alertError = self?.service.alertError
            self?.showAlertError = val
        }
        .store(in: &self.cancellables)
        
        service.model.$flashMode.sink { [weak self] (mode) in
            self?.isFlashOn = mode == .on
        }
        .store(in: &self.cancellables)
        
        service.model.$willCapturePhoto.sink { [weak self] (val) in
            self?.willCapturePhoto = val
        }
        .store(in: &self.cancellables)
        self.$selectedCameraMode.dropFirst().sink { [weak self] newMode in
            self?.service.model.cameraMode = newMode
        }
        .store(in: &self.cancellables)
        service.model.$isRecordingVideo.sink { [weak self] capturing in
            self?.isRecordingVideo = capturing
        }
        .store(in: &self.cancellables)
        
        $isLivePhotoEnabled.dropFirst().sink { enabled in
            self.service.isLivePhotoEnabled = enabled
        }.store(in: &cancellables)
        
        loadThumbnail()
    }
    
    func configure() {
        service.checkForPermissions()
        service.configure()
    }
    
    func loadThumbnail() {
        Task {
            let media: [EncryptedMedia] = await self.fileReader.enumerateMedia()
            guard let firstMedia = media.first else {
                self.thumbnailImage = nil
                return
            }
            let cleartextThumb = try await self.fileReader.loadMediaPreview(for: firstMedia)
            guard let thumbnail = UIImage(data: cleartextThumb.source) else {
                self.thumbnailImage = nil
                return
            }
            await MainActor.run(body: {
                self.thumbnailImage = thumbnail
            })
        }
    }
    
    func captureButtonPressed() {
        switch selectedCameraMode {
        case .photo:
            service.capturePhoto()
        case .video:
            service.toggleVideoCapture()
        }
    }
    
    func flipCamera() {
        service.changeCamera()
    }
    
    func zoom(with factor: CGFloat) {
        service.set(zoom: factor)
    }
    
    func switchFlash() {
        service.model.flashMode = service.model.flashMode == .on ? .off : .on
    }
}
