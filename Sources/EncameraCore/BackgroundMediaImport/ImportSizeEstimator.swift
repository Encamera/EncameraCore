//
//  ImportSizeEstimator.swift
//  EncameraCore
//

import Foundation
import Photos

/// Sizes an import selection before anything is loaded, one entry per item
/// in selection order. `nil` means the size can't be known without loading.
public protocol ImportSizeEstimating {
    func sizes(for results: [MediaSelectionResult]) -> [Int64?]
    func sizes(for urls: [URL]) -> [Int64?]
}

public struct ImportSizeEstimator: ImportSizeEstimating {

    /// Bytes per pixel assumed for a photo whose resource size is unreadable.
    static let estimatedPhotoBytesPerPixel = 0.5
    /// Bitrate assumed for a video whose resource size is unreadable.
    static let estimatedVideoBitsPerSecond = 12_000_000.0

    public init() {}

    public func sizes(for results: [MediaSelectionResult]) -> [Int64?] {
        results.map(size(for:))
    }

    public func sizes(for urls: [URL]) -> [Int64?] {
        urls.map(size(for:))
    }

    func size(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return nil
        }
        if let allocated = values.totalFileAllocatedSize {
            return Int64(allocated)
        }
        return values.fileSize.map(Int64.init)
    }

    func size(for result: MediaSelectionResult) -> Int64? {
        switch result {
        case .phAsset(let asset):
            return size(for: asset)
        case .phPickerResult:
            return size(forAssetIdentifier: result.assetIdentifier)
        }
    }

    /// A picker result only carries an identifier, and it only resolves to an
    /// asset when the app has library authorization.
    func size(forAssetIdentifier identifier: String?) -> Int64? {
        guard let identifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        return size(for: asset)
    }

    /// Sums the resources `MediaLoaderService` imports for the asset: photo and
    /// paired video for a Live Photo, otherwise the primary photo or video.
    func size(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        let imported = Self.importedResources(from: resources, isLivePhoto: asset.mediaSubtypes.contains(.photoLive))
        let sizes = imported.map(Self.resourceFileSize)
        if !imported.isEmpty, sizes.allSatisfy({ $0 != nil }) {
            return sizes.compactMap { $0 }.reduce(0, +)
        }
        return Self.estimatedSize(for: asset)
    }

    static func importedResources(from resources: [PHAssetResource], isLivePhoto: Bool) -> [PHAssetResource] {
        if isLivePhoto {
            return resources.filter { $0.type == .photo || $0.type == .pairedVideo }
        }
        // The loader requests the current version, so an edit is imported as
        // its full-size render rather than the original.
        let preference: [PHAssetResourceType] = [.fullSizePhoto, .photo, .fullSizeVideo, .video]
        for type in preference {
            if let resource = resources.first(where: { $0.type == type }) {
                return [resource]
            }
        }
        return []
    }

    /// The resource's byte size. PhotoKit has no public API for this; the
    /// value is read through KVC and kept to this one function so it can be
    /// swapped for `estimatedSize(for:)` alone.
    private static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// A public-API estimate from pixel dimensions or duration.
    static func estimatedSize(for asset: PHAsset) -> Int64? {
        switch asset.mediaType {
        case .image:
            let pixels = Double(asset.pixelWidth * asset.pixelHeight)
            var bytes = pixels * estimatedPhotoBytesPerPixel
            if asset.mediaSubtypes.contains(.photoLive) {
                bytes += 3 * estimatedVideoBitsPerSecond / 8
            }
            return pixels > 0 ? Int64(bytes) : nil
        case .video:
            return asset.duration > 0 ? Int64(asset.duration * estimatedVideoBitsPerSecond / 8) : nil
        default:
            return nil
        }
    }
}
