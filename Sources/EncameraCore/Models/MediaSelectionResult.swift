import Foundation
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// A common result type for media selection that can be produced by both custom and standard photo pickers
public enum MediaSelectionResult {
    case phAsset(PHAsset)
    case phPickerResult(PHPickerResult)
    
    /// The asset identifier if available
    public var assetIdentifier: String? {
        switch self {
        case .phAsset(let asset):
            return asset.localIdentifier
        case .phPickerResult(let result):
            return result.assetIdentifier
        }
    }
}
