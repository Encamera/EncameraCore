import Foundation

//  MARK: CameraService Enums
extension CameraService {
    enum LivePhotoMode {
        case on
        case off
    }
    
    enum DepthDataDeliveryMode {
        case on
        case off
    }
    
    enum PortraitEffectsMatteDeliveryMode {
        case on
        case off
    }
    
    enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    
    enum SetupError: Error {
        case defaultVideoDeviceUnavailable
        case defaultAudioDeviceUnavailable
        case couldNotAddVideoInputToSession
        case couldNotCreateVideoDeviceInput(avFoundationError: Error)
        case couldNotAddPhotoOutputToSession
        case couldNotAddMetadataOutputToSession
    }
    
    enum CaptureMode: Int {
        case photo = 0
        case movie = 1
    }
}
