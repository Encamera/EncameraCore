//
//  CameraPreview.swift
//  Encamera
//
//  Created by Rolando Rodriguez on 10/17/20.
//

import SwiftUI
import AVFoundation
import Combine

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
        
        
        var session: AVCaptureSession? {
            set {
                videoPreviewLayer.session = newValue
            }
            get {
                videoPreviewLayer.session
            }
        }
        
        private var cancellables = Set<AnyCancellable>()

        init(modePublisher: AnyPublisher<CameraMode, Never>, session: AVCaptureSession) {
            super.init(frame: .zero)
            modePublisher.dropFirst().sink { mode in
                self.switchMode(mode)
            }.store(in: &cancellables)
            self.session = session
            NotificationCenter.default
                .publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { _ in
                    self.session = nil
                }.store(in: &cancellables)
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
    
    func makeUIView(context: Context) -> VideoPreviewView {
        
        return VideoPreviewView(modePublisher: self.modePublisher, session: self.session)
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        
    }
}

struct CameraPreview_Previews: PreviewProvider {
    static var previews: some View {
        CameraPreview(session: AVCaptureSession(), modePublisher: Just(.video).eraseToAnyPublisher())
            .frame(height: 300)
    }
}
