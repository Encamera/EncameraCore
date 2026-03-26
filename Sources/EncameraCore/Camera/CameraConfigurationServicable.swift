import Foundation
import AVFoundation

protocol CameraConfigurationServicable {
    var session: AVCaptureSession { get }
    init(model: CameraConfigurationServiceModel)
    func configure() async
    func checkForPermissions() async
    func stop(observeRestart: Bool) async
    func start() async
    func focus(at focusPoint: CGPoint) async
    func set(zoom: ZoomLevel) async
    func set(rotationAngle: CGFloat) async
    func flipCameraDevice() async
    func configureForMode(targetMode: CameraMode) async
    func setDelegate(_ delegate: CameraConfigurationServicableDelegate) async
}
