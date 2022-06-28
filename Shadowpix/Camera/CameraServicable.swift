//
//  CameraServicable.swift
//  Shadowpix
//
//  Created by Alexander Freas on 26.06.22.
//

import Foundation
import AVFoundation

protocol CameraServicable {

    var model: CameraServiceModel { get set }
    var alertError: AlertError { get set }
    var fileWriter: FileWriter? { get set }
    var session: AVCaptureSession { get }
    var isLivePhotoEnabled: Bool { get set }
    init(keyManager: KeyManager, model: CameraServiceModel)
    func configure()
    func checkForPermissions()
    func changeCamera()
    func focus(at focusPoint: CGPoint)
    func stop()
    func start()
    func set(zoom: CGFloat)
    func toggleVideoCapture()
    func capturePhoto()
}
