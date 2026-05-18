import AVFoundation

public struct ConstituentDeviceInfo {
    public let deviceType: AVCaptureDevice.DeviceType

    public init(deviceType: AVCaptureDevice.DeviceType) {
        self.deviceType = deviceType
    }
}

public protocol ZoomableDevice: AnyObject {
    var zoomConstituentDevices: [ConstituentDeviceInfo] { get }
    var virtualDeviceSwitchOverVideoZoomFactors: [NSNumber] { get }
    var minAvailableVideoZoomFactor: CGFloat { get }
    var zoomDeviceActiveFormatVideoMaxZoomFactor: CGFloat { get }
    var zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors: [CGFloat] { get }
    var zoomDeviceType: AVCaptureDevice.DeviceType { get }
    var zoomDeviceLocalizedName: String { get }
    var videoZoomFactor: CGFloat { get set }
    func lockForConfiguration() throws
    func unlockForConfiguration()
}

extension AVCaptureDevice: ZoomableDevice {
    public var zoomConstituentDevices: [ConstituentDeviceInfo] {
        constituentDevices.map { ConstituentDeviceInfo(deviceType: $0.deviceType) }
    }

    public var zoomDeviceActiveFormatVideoMaxZoomFactor: CGFloat {
        activeFormat.videoMaxZoomFactor
    }

    public var zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors: [CGFloat] {
        activeFormat.secondaryNativeResolutionZoomFactors
    }

    public var zoomDeviceType: AVCaptureDevice.DeviceType {
        deviceType
    }

    public var zoomDeviceLocalizedName: String {
        localizedName
    }
}
