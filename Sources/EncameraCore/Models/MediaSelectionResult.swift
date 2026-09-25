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
    var assetIdentifier: String? {
        switch self {
        case .phAsset(let asset):
            return asset.localIdentifier
        case .phPickerResult(let result):
            return result.assetIdentifier
        }
    }
    
    /// Creates an item provider for the media.
    ///
    /// `public` so app-side importers can stream a picked file without copying it —
    /// `loadFileRepresentation` hands back a system-owned temp URL, which is the only
    /// way to read a 1 GB video without first duplicating it on disk.
    public func createItemProvider() -> NSItemProvider {
        switch self {
        case .phAsset(let asset):
            return createItemProvider(for: asset)
        case .phPickerResult(let result):
            return result.itemProvider
        }
    }
    
    private func createItemProvider(for asset: PHAsset) -> NSItemProvider {
        let provider = NSItemProvider()
        
        if asset.mediaType == .image {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { completion in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.version = .current
                
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    guard let data else {
                        completion(nil, BackgroundImportError.fromPhotoKitInfo(info))
                        return
                    }
                    completion(data, nil)
                }
                return Progress()
            }
            
            if asset.mediaSubtypes.contains(.photoLive) {
                // PHLivePhoto doesn't conform to _ObjectiveCBridgeable, so we use canLoadObject
                // The actual loading will be handled by the existing loadObject implementation
                _ = provider.canLoadObject(ofClass: PHLivePhoto.self)
            }
        } else if asset.mediaType == .video {
            provider.registerFileRepresentation(forTypeIdentifier: UTType.movie.identifier, visibility: .all) { completion in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.version = .current
                
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    guard let urlAsset = avAsset as? AVURLAsset else {
                        completion(nil, false, BackgroundImportError.fromPhotoKitInfo(info))
                        return
                    }
                    
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".mov")
                    do {
                        try FileManager.default.copyItem(at: urlAsset.url, to: tempURL)
                        completion(tempURL, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return Progress()
            }
        }
        
        return provider
    }
}

/// Protocol for components that handle media selection
protocol MediaSelectionHandler {
    func handleSelectedMedia(results: [MediaSelectionResult])
} 