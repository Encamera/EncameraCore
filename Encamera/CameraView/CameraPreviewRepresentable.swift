import SwiftUI
import AVFoundation
import Combine
import EncameraCore

struct CameraPreviewRepresentable: UIViewControllerRepresentable {

    let session: AVCaptureSession
    let modePublisher: AnyPublisher<CameraMode, Never>
    let capturePublisher: AnyPublisher<Void, Never>

    func makeUIViewController(context: Context) -> CameraPreviewController {
        let controller = CameraPreviewController(
            session: session,
            modePublisher: modePublisher,
            capturePublisher: capturePublisher
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraPreviewController, context: Context) {
        // No updates needed currently, as the controller manages its state internally based on publishers and notifications.
    }

    typealias UIViewControllerType = CameraPreviewController
} 