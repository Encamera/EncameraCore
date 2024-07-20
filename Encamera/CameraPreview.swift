import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import EncameraCore

struct CameraPreview: UIViewRepresentable {

    class VideoPreviewView: UIView {

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            guard let layer = layer as? AVCaptureVideoPreviewLayer else {
                fatalError("Expected `AVCaptureVideoPreviewLayer` type for layer. Check PreviewView.layerClass implementation.")
            }
            return layer
        }

        override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }

        var session: AVCaptureSession?

        private var cancellables = Set<AnyCancellable>()

        init(modePublisher: AnyPublisher<CameraMode, Never>, capturePublisher: AnyPublisher<Void, Never>, session: AVCaptureSession) {
            super.init(frame: .zero)
            modePublisher.dropFirst().sink { mode in
                self.switchMode(mode)
            }.store(in: &cancellables)
            capturePublisher.receive(on: RunLoop.main).sink { _ in
                self.flashCaptureAnimation()
            }.store(in: &cancellables)
            self.session = session
            videoPreviewLayer.session = session
            self.videoPreviewLayer.videoGravity = .resizeAspectFill
        }

        private func switchMode(_ mode: CameraMode) {
            switch mode {
            case .photo:
                self.videoPreviewLayer.videoGravity = .resizeAspectFill
            case .video:
                self.videoPreviewLayer.videoGravity = .resizeAspectFill
            }
        }

        private func flashCaptureAnimation() {
            let flashAnimation = CABasicAnimation(keyPath: "opacity")
            flashAnimation.fromValue = 1.0
            flashAnimation.toValue = 0.0
            flashAnimation.duration = 0.1
            flashAnimation.autoreverses = true

            videoPreviewLayer.add(flashAnimation, forKey: "flashAnimation")

            flashAnimation.beginTime = CACurrentMediaTime()
            self.videoPreviewLayer.add(flashAnimation, forKey: "flashAnimation")
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    let session: AVCaptureSession
    let modePublisher: AnyPublisher<CameraMode, Never>
    var capturePublisher: AnyPublisher<Void, Never>
    private var cancellables = Set<AnyCancellable>()

    init(modePublisher: AnyPublisher<CameraMode, Never>, capturePublisher: AnyPublisher<Void, Never>, session: AVCaptureSession) {
        self.modePublisher = modePublisher
        self.capturePublisher = capturePublisher
        self.session = session
    }

    func makeUIView(context: Context) -> VideoPreviewView {
        return VideoPreviewView(
            modePublisher: self.modePublisher,
            capturePublisher: self.capturePublisher,
            session: self.session
        )
    }

    func updateUIView(_ uiView: VideoPreviewView, context: Context) {

    }
}
