import Foundation
import UIKit
import AVFoundation

extension UIDeviceOrientation {
    /// Returns the video rotation angle corresponding to this device orientation.
    /// Maps device orientation to the angle needed for horizon-level capture/preview.
    /// Note: `landscapeLeft` maps to 0° (landscape right in video terms) and vice versa,
    /// because the camera sensor orientation is opposite to the device body.
    public var videoRotationAngle: CGFloat? {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        default: return nil
        }
    }
}

extension AVCaptureDevice.DiscoverySession {
    var uniqueDevicePositionsCount: Int {

        var uniqueDevicePositions = [AVCaptureDevice.Position]()

        for device in devices where !uniqueDevicePositions.contains(device.position) {
            uniqueDevicePositions.append(device.position)
        }

        return uniqueDevicePositions.count
    }
}
