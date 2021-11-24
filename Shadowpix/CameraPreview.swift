//
//  CameraPreview.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/17/20.
//

import SwiftUI
import AVFoundation
import Combine

struct CameraPreview: UIViewRepresentable {
    class VideoPreviewView: UIView {
        
        
        var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                removeVideoPreviewLayer()
                addVideoPreviewLayer()
            }
        }
        
        private func removeVideoPreviewLayer() {
            videoPreviewLayer?.removeFromSuperlayer()
        }
        
        private func addVideoPreviewLayer() {
            guard let videoPreviewLayer = videoPreviewLayer else {
                return
            }

            layer.addSublayer(videoPreviewLayer)
            videoPreviewLayer.frame = layer.frame
        }
        private var cancellables = Set<AnyCancellable>()

        init() {
            super.init(frame: .zero)
            NotificationCenter.default
                .publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { _ in
                    self.removeVideoPreviewLayer()
                }.store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: Notification.Name.AVCaptureSessionDidStartRunning)
                .receive(on: DispatchQueue.main)
                .sink { _ in
                    self.addVideoPreviewLayer()
                }.store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: UIApplication.willResignActiveNotification)
                .sink { _ in
                    self.removeVideoPreviewLayer()
                }.store(in: &cancellables)


        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer()
        layer.cornerRadius = 0
        layer.session = session
        layer.connection?.videoOrientation = .portrait
        view.videoPreviewLayer = layer
        return view
    }
    
    func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        
    }
}

struct CameraPreview_Previews: PreviewProvider {
    static var previews: some View {
        CameraPreview(session: AVCaptureSession())
            .frame(height: 300)
    }
}
