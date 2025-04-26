import UIKit
import AVFoundation
import Combine
import EncameraCore

// MARK: - VideoPreviewView (Moved from CameraPreview.swift)

class VideoPreviewView: UIView {

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected `AVCaptureVideoPreviewLayer` type for layer. Check VideoPreviewView.layerClass implementation.")
        }
//         Ensure the connection is available before returning the layer
         // The connection might be nil briefly during setup or teardown.
         guard layer.connection != nil else {
              print("Video preview layer connection is nil.")
              // Potentially return a default layer or handle appropriately
              // For now, proceeding with the potentially nil connection layer
              return layer
         }
        
        return layer
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var session: AVCaptureSession? {
        get { videoPreviewLayer.session }
        set { videoPreviewLayer.session = newValue }
    }

    private var cancellables = Set<AnyCancellable>()
    private var modePublisher: AnyPublisher<CameraMode, Never>
    private var capturePublisher: AnyPublisher<Void, Never>

    init(modePublisher: AnyPublisher<CameraMode, Never>, capturePublisher: AnyPublisher<Void, Never>) {
        self.modePublisher = modePublisher
        self.capturePublisher = capturePublisher
        super.init(frame: .zero)

        self.videoPreviewLayer.videoGravity = .resizeAspectFill // Default gravity

        setupBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBindings() {
        modePublisher.dropFirst().sink { [weak self] mode in
            self?.switchMode(mode)
        }.store(in: &cancellables)

        capturePublisher.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.flashCaptureAnimation()
        }.store(in: &cancellables)
    }

    private func switchMode(_ mode: CameraMode) {
        // Adjust gravity based on mode if needed in the future
        switch mode {
        case .photo, .video:
            self.videoPreviewLayer.videoGravity = .resizeAspectFill
        }
    }

    private func flashCaptureAnimation() {
        // Ensure layer is available for animation
         guard let layer = self.layer as? AVCaptureVideoPreviewLayer else { return }

        let flashView = UIView(frame: self.bounds)
        flashView.backgroundColor = .white
        flashView.alpha = 0
        self.addSubview(flashView)

        UIView.animate(withDuration: 0.1, delay: 0, options: [.autoreverse], animations: {
            flashView.alpha = 1.0
        }, completion: { _ in
            flashView.removeFromSuperview()
        })
    }
    
    func updateOrientation(_ orientation: AVCaptureVideoOrientation) {
        // Ensure the connection is available before setting the orientation
        guard let connection = self.videoPreviewLayer.connection else {
            print("Attempted to set orientation, but videoPreviewLayer.connection is nil.")
            return
        }
        
        // Check if the connection supports video orientation changes
        guard connection.isVideoOrientationSupported else {
             print("Video orientation is not supported on the current connection.")
             return
        }
        
        connection.videoOrientation = orientation
    }
}


// MARK: - CameraPreviewController

class CameraPreviewController: UIViewController {

    private let session: AVCaptureSession
    private let modePublisher: AnyPublisher<CameraMode, Never>
    private let capturePublisher: AnyPublisher<Void, Never>
    private var videoPreviewView: VideoPreviewView!

    // MARK: - Initialization

    init(session: AVCaptureSession, modePublisher: AnyPublisher<CameraMode, Never>, capturePublisher: AnyPublisher<Void, Never>) {
        self.session = session
        self.modePublisher = modePublisher
        self.capturePublisher = capturePublisher
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupVideoPreviewView()
        addOrientationObserver()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Set initial orientation
        updatePreviewLayerOrientation()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ensure preview view frame matches bounds after layout changes (e.g., initial setup)
        videoPreviewView.frame = view.bounds
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
         print("CameraPreviewController deinit")
    }

    // MARK: - Setup

    private func setupVideoPreviewView() {
        videoPreviewView = VideoPreviewView(modePublisher: modePublisher, capturePublisher: capturePublisher)
        videoPreviewView.session = self.session // Assign the session
        view.addSubview(videoPreviewView)

        // Layout constraints
        videoPreviewView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoPreviewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoPreviewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoPreviewView.topAnchor.constraint(equalTo: view.topAnchor),
            videoPreviewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Rotation Handling

    override var shouldAutorotate: Bool {
        return false // Prevent this controller's view from rotating
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait // Only support portrait for this controller's view
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
    
    private func addOrientationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func deviceOrientationDidChange() {
        updatePreviewLayerOrientation()
    }

    private func updatePreviewLayerOrientation() {
        let currentDeviceOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation

        switch currentDeviceOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .landscapeLeft:
            // Note: LandscapeLeft physical orientation corresponds to LandscapeRight video orientation
            videoOrientation = .landscapeRight
        case .landscapeRight:
            // Note: LandscapeRight physical orientation corresponds to LandscapeLeft video orientation
            videoOrientation = .landscapeLeft
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .faceUp, .faceDown, .unknown:
            // Keep the last known orientation or default to portrait if none.
            // Check if the connection already has a valid orientation.
            if let existingOrientation = videoPreviewView?.videoPreviewLayer.connection?.videoOrientation, existingOrientation != .portraitUpsideDown { // Avoid defaulting to upside down if briefly face up/down
                videoOrientation = existingOrientation
             } else {
                 videoOrientation = .portrait // Default if no valid previous orientation
             }
        @unknown default:
            videoOrientation = .portrait
        }
        
        // Update the preview layer's connection orientation
        videoPreviewView?.updateOrientation(videoOrientation)

    }
} 
