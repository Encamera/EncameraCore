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
    private let service: CameraService
    var key: Published<ImageKey?>.Publisher
    @Published var photo: Photo!
    
    @Published var showAlertError = false
    
    @Published var isFlashOn = false
    @Published var isRecordingVideo = false
    @Published var willCapturePhoto = false
    @Published var showCameraView = true
    @Published var selectedCameraMode: CameraMode = .photo
    
    var alertError: AlertError!
    
    var session: AVCaptureSession
    
    private var cancellables = Set<AnyCancellable>()
    
    init(key: Published<ImageKey?>.Publisher) {
        self.key = key
        self.service = CameraService(key: self.key)
        self.session = service.session
        
        
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                self.showCameraView = false
                self.service.stop(completion: nil)
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
                self.showCameraView = false
                self.service.stop(completion: nil)
            }.store(in: &cancellables)

        
        service.$shouldShowAlertView.sink { [weak self] (val) in
            self?.alertError = self?.service.alertError
            self?.showAlertError = val
        }
        .store(in: &self.cancellables)
        
        service.$flashMode.sink { [weak self] (mode) in
            self?.isFlashOn = mode == .on
        }
        .store(in: &self.cancellables)
        
        service.$willCapturePhoto.sink { [weak self] (val) in
            self?.willCapturePhoto = val
        }
        .store(in: &self.cancellables)
        self.$selectedCameraMode.sink { [weak self] newMode in
            self?.service.mode = newMode
        }
        .store(in: &self.cancellables)
        service.$isRecordingVideo.sink { [weak self] capturing in
            self?.isRecordingVideo = capturing
        }
        .store(in: &self.cancellables)
    }
    
    func configure() {
        service.checkForPermissions()
        service.configure()
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
        service.flashMode = service.flashMode == .on ? .off : .on
    }
}
