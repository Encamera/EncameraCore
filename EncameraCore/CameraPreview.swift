import SwiftUI
import AVFoundation
import Combine
import MediaPlayer

struct CameraPreview: UIViewRepresentable {
    
    
    
    class VideoPreviewView: UIView {
        
        private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: -100, width: 0, height: 0)) // override volume view

        private func setupVolumeButton() {
            addSubview(volumeView)

            setVolume(0.5) { // in case app launches with volume at max/min already
                // need to wait until initial volume setting is done
                // so it doesn't get triggered on launch

                let audioSession = AVAudioSession()
                try? audioSession.setActive(true)
                audioSession.addObserver(self, forKeyPath: "outputVolume", options: NSKeyValueObservingOptions.new, context: nil)
            }
        }

        private func setVolume(_ volume: Float, completion: (() -> Void)? = nil) {
            let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
                slider?.value = volume

                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.01) {
                    // needed to wait a bit before completing so the observer doesn't pick up the manualq volume change
                    completion?()
                }
            }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "outputVolume" {
                setVolume(0.5) // keep from reaching max or min volume so button keeps working
                NotificationUtils.sendHardwareButtonPressed()
            }
        }
        
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
            NotificationUtils.didEnterBackgroundPublisher
                .sink { _ in
                    self.videoPreviewLayer.session = nil
                    
                }.store(in: &cancellables)
            NotificationUtils.didBecomeActivePublisher
                .sink { _ in
                    self.videoPreviewLayer.session = self.session
                    
                }.store(in: &cancellables)
            
            setupVolumeButton()
        }
        
        private func switchMode(_ mode: CameraMode) {
            switch mode {

            case .photo:
                self.videoPreviewLayer.videoGravity = .resizeAspect
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
        return VideoPreviewView(modePublisher: self.modePublisher, session: self.session)
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        
    }
}

struct CameraPreview_Previews: PreviewProvider {
    static var previews: some View {
        CameraPreview(
            session: AVCaptureSession(),
            modePublisher: Just(.video).eraseToAnyPublisher())
            .frame(height: 300)
    }
}
