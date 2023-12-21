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

        init(modePublisher: AnyPublisher<CameraMode, Never>, session: AVCaptureSession) {
            super.init(frame: .zero)
            modePublisher.dropFirst().sink { mode in
                self.switchMode(mode)
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
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    let session: AVCaptureSession
    let modePublisher: AnyPublisher<CameraMode, Never>
    var cancellables = Set<AnyCancellable>()

    func makeUIView(context: Context) -> VideoPreviewView {
        return VideoPreviewView(
            modePublisher: self.modePublisher,
            session: self.session
        )
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        
    }
}

//struct CameraPreview_Previews: PreviewProvider {
//    static var previews: some View {
//        CameraPreview(
//            session: AVCaptureSession(),
//            modePublisher: Just(.video).eraseToAnyPublisher())
//            .frame(height: 300)
//    }
//}
