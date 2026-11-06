//
//  CameraPermissionsService.swift
//
//
//  Created by Alexander Freas on 10.10.23.
//

import Foundation
import AVFoundation
import Combine

public enum PermissionError: Error {
    case denied
}

public class CameraPermissionsService: ObservableObject {

    public static let shared = CameraPermissionsService()

    @MainActor
    @Published private(set) public var isCameraAccessAuthorized: Bool = false
    @MainActor
    @Published private(set) public var isMicrophoneAccessAuthorized: Bool = false

    private init() {
        // Initializing with current permission status
        Task { @MainActor in
            isCameraAccessAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            isMicrophoneAccessAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    public var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public func requestMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            Task { @MainActor in
                isMicrophoneAccessAuthorized = true
            }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Task { @MainActor in
                isMicrophoneAccessAuthorized = granted
            }
            if !granted {
                throw PermissionError.denied
            }
        default:
            throw PermissionError.denied
        }
    }
}
