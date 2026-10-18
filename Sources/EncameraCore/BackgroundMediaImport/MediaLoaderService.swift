//
//  MediaLoaderService.swift
//  EncameraCore
//
//  Created for separation of concerns refactoring
//

import Foundation
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Result of loading a single media item from the photo library
public struct LoadedMediaItem {
    public let media: [CleartextMedia]
    public let metadata: EncryptedFileMetadata?
    public let assetIdentifier: String?
    
    public init(media: [CleartextMedia], metadata: EncryptedFileMetadata?, assetIdentifier: String?) {
        self.media = media
        self.metadata = metadata
        self.assetIdentifier = assetIdentifier
    }
}

/// Result of loading a batch of media from the photo library
public struct LoadedMediaBatch {
    public let media: [CleartextMedia]
    public let assetIdentifiers: [String]
    public let successfulLoads: Int
    public let failedLoads: Int
    
    public init(media: [CleartextMedia], assetIdentifiers: [String], successfulLoads: Int, failedLoads: Int) {
        self.media = media
        self.assetIdentifiers = assetIdentifiers
        self.successfulLoads = successfulLoads
        self.failedLoads = failedLoads
    }
}

/// Service responsible for loading media from the Photos library into temporary storage
/// This handles extraction of PHAssets and PHPickerResults into CleartextMedia objects
@MainActor
public class MediaLoaderService: DebugPrintable {
    
    private var tempDirectoryChecked = false
    
    /// Metadata extractor for extracting media metadata
    private let metadataExtractor = MediaMetadataExtractor()
    
    public init() {}
    
    // MARK: - Public API
    
    /// Loads media from an array of MediaSelectionResults
    /// Returns a batch with all successfully loaded media and statistics
    public func loadMedia(from results: [MediaSelectionResult]) async throws -> LoadedMediaBatch {
        try await ensureTempDirectoryExists()
        
        var allMedia: [CleartextMedia] = []
        var assetIdentifiers: [String] = []
        var successfulLoads = 0
        var failedLoads = 0
        
        for (index, result) in results.enumerated() {
            printDebug("📄 Processing result \(index + 1)/\(results.count)")
            
            do {
                let loaded = try await loadSingleMedia(from: result)
                
                allMedia.append(contentsOf: loaded.media)
                successfulLoads += 1
                
                if let assetId = loaded.assetIdentifier {
                    assetIdentifiers.append(assetId)
                }
                
            } catch {
                failedLoads += 1
                logMediaLoadError(error, for: result)
            }
        }
        
        printDebug("📈 Summary - Successful: \(successfulLoads), Failed: \(failedLoads), Total media: \(allMedia.count)")
        
        return LoadedMediaBatch(
            media: allMedia,
            assetIdentifiers: assetIdentifiers,
            successfulLoads: successfulLoads,
            failedLoads: failedLoads
        )
    }
    
    /// Loads media from a single MediaSelectionResult
    /// Returns the loaded media, metadata, and optional asset ID. `progress`
    /// reports 0...1 while iCloud downloads the original, on any queue.
    public func loadSingleMedia(from result: MediaSelectionResult,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> LoadedMediaItem {
        try await ensureTempDirectoryExists()
        
        switch result {
        case .phAsset(let asset):
            let (media, slowMotion) = try await loadMediaFromAsset(asset, progress: progress)
            var metadata = await metadataExtractor.extractMetadata(from: asset)
            if let originalFilename = media.compactMap(\.originalFilename).first {
                metadata.originalFilename = originalFilename
            }
            if let slowMotion {
                metadata.video = metadata.video ?? .init(duration: asset.duration)
                metadata.video?.slowMotion = slowMotion
            }
            return LoadedMediaItem(media: media, metadata: metadata, assetIdentifier: asset.localIdentifier)
            
        case .phPickerResult(let pickerResult):
            let media = try await loadMediaAsync(result: pickerResult, progress: progress)
            var metadata: EncryptedFileMetadata?
            if let assetId = pickerResult.assetIdentifier {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
                if let asset = fetchResult.firstObject {
                    metadata = await metadataExtractor.extractMetadata(from: asset)
                }
            }
            if metadata == nil, let firstMedia = media.first, let url = firstMedia.url {
                metadata = await metadataExtractor.extractMetadata(from: url, mediaType: firstMedia.mediaType)
            }
            if let originalFilename = media.compactMap(\.originalFilename).first {
                metadata?.originalFilename = originalFilename
            }
            return LoadedMediaItem(media: media, metadata: metadata, assetIdentifier: pickerResult.assetIdentifier)
        }
    }
    
    /// Legacy method for backwards compatibility - returns tuple format
    public func loadSingleMediaTuple(from result: MediaSelectionResult) async throws -> (media: [CleartextMedia], assetId: String?) {
        let loaded = try await loadSingleMedia(from: result)
        return (loaded.media, loaded.assetIdentifier)
    }
    
    // MARK: - Private Implementation
    
    // MARK: - PHPickerResult Loading
    
    private func loadMediaAsync(result: PHPickerResult, progress: @escaping @Sendable (Double) -> Void) async throws -> [CleartextMedia] {
        let isLivePhoto = result.itemProvider.canLoadObject(ofClass: PHLivePhoto.self)
        if isLivePhoto {
            return try await loadLivePhoto(result: result, progress: progress)
        } else {
            return [try await loadMedia(result: result, progress: progress)]
        }
    }
    
    private func loadMedia(result: PHPickerResult, progress: @escaping @Sendable (Double) -> Void) async throws -> CleartextMedia {
        let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let preferredType = isVideo ? UTType.movie.identifier : UTType.image.identifier
        let suggestedName = result.itemProvider.suggestedName

        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        let loaded: (url: URL, originalFilename: String)? = try await withCheckedThrowingContinuation { continuation in
            let loadProgress = result.itemProvider.loadFileRepresentation(forTypeIdentifier: preferredType) { url, error in
                guard let url = url else {
                    debugPrint("Error loading file representation: \(String(describing: error))")
                    continuation.resume(returning: nil)
                    return
                }

                let originalFilename = url.lastPathComponent
                let fileName = NSUUID().uuidString + (isVideo ? ".mov" : ".jpeg")
                let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)

                do {
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    debugPrint("File copied to: \(destinationURL)")
                    continuation.resume(returning: (destinationURL, originalFilename))
                } catch {
                    debugPrint("Error copying file: \(error)")
                    continuation.resume(throwing: error)
                }
            }
            observation = Self.forward(loadProgress, to: progress)
        }

        guard let loaded = loaded else {
            printDebug("Error loading file representation, url is nil")
            throw BackgroundImportError.mismatchedType
        }

        let originalFilename = loaded.originalFilename.isEmpty ? suggestedName : loaded.originalFilename
        return CleartextMedia(
            source: loaded.url,
            mediaType: isVideo ? .video : .photo,
            id: UUID().uuidString,
            originalFilename: originalFilename
        )
    }
    
    /// The picker hands over a Live Photo in two steps, fetching the object and
    /// then writing its resources; each takes half of the item's progress.
    private func loadLivePhoto(result: PHPickerResult, progress: @escaping @Sendable (Double) -> Void) async throws -> [CleartextMedia] {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        let assetResources = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[PHAssetResource], Error>) in
            let loadProgress = result.itemProvider.loadObject(ofClass: PHLivePhoto.self) { (object, error) in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let livePhoto = object as? PHLivePhoto else {
                    continuation.resume(throwing: NSError(domain: "LivePhotoErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not load PHLivePhoto from the result"]))
                    return
                }
                
                continuation.resume(returning: PHAssetResource.assetResources(for: livePhoto))
            }
            observation = Self.forward(loadProgress) { progress($0 * 0.5) }
        }
        observation?.invalidate()

        return try await processAssetResources(assetResources) { progress(0.5 + $0 * 0.5) }
    }
    
    // MARK: - PHAsset Loading
    
    private func loadMediaFromAsset(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> (media: [CleartextMedia], slowMotion: SlowMotionRamp?) {
        if asset.mediaSubtypes.contains(.photoLive) {
            return (try await loadLivePhotoFromAsset(asset, progress: progress), nil)
        } else if asset.mediaType == .video {
            let (media, slowMotion) = try await loadVideoFromAsset(asset, progress: progress)
            return ([media], slowMotion)
        } else {
            return ([try await loadRegularMediaFromAsset(asset, progress: progress)], nil)
        }
    }

    private func loadVideoFromAsset(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> (media: CleartextMedia, slowMotion: SlowMotionRamp?) {
        let id = UUID().uuidString
        let destinationURL = URL.tempMediaDirectory.appendingPathComponent(id + ".mov")
        let slowMotion = try await PhotoKitVideoLoader.load(asset, to: destinationURL, progress: progress)
        if let slowMotion {
            printDebug("Kept slow-motion original with \(slowMotion.segments.count) ramp segment(s)")
        }
        let media = CleartextMedia(source: destinationURL,
                                   mediaType: .video,
                                   id: id,
                                   originalFilename: MediaMetadataExtractor.primaryResourceFilename(for: asset))
        return (media, slowMotion)
    }
    
    private func loadRegularMediaFromAsset(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> CleartextMedia {
        let id = UUID().uuidString
        let originalFilename = MediaMetadataExtractor.primaryResourceFilename(for: asset)
        
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.progressHandler = { fraction, _, _, _ in progress(fraction) }
            
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard let data = data else {
                    continuation.resume(throwing: BackgroundImportError.fromPhotoKitInfo(info))
                    return
                }
                
                let fileName = id + ".jpeg"
                let destinationURL = URL.tempMediaDirectory.appendingPathComponent(fileName)
                
                do {
                    try data.write(to: destinationURL)
                    let media = CleartextMedia(source: destinationURL, mediaType: .photo, id: id, originalFilename: originalFilename)
                    continuation.resume(returning: media)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func loadLivePhotoFromAsset(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> [CleartextMedia] {
        let resources = PHAssetResource.assetResources(for: asset)
        return try await processAssetResources(resources, progress: progress)
    }
    
    // MARK: - Helper Methods
    
    /// Writes a Live Photo's photo and paired video out, each taking an equal
    /// share of `progress` — their sizes are not known until they download.
    private func processAssetResources(_ resources: [PHAssetResource],
                                       progress: @escaping @Sendable (Double) -> Void) async throws -> [CleartextMedia] {
        var cleartextMediaArray: [CleartextMedia] = []
        let id = UUID().uuidString
        let resources = resources.filter { $0.type == .photo || $0.type == .pairedVideo }
        let weights = ComponentProgressWeights(byteCounts: resources.map { _ in nil })

        for (index, resource) in resources.enumerated() {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { fraction in progress(weights.overall(component: index, fraction: fraction)) }
            
            let documentsDirectory = URL.tempMediaDirectory
            let fileExtension = (resource.originalFilename as NSString).pathExtension
            let uniqueFileName = "\(UUID().uuidString).\(fileExtension.isEmpty ? "data" : fileExtension)"
            let fileURL = documentsDirectory.appendingPathComponent(uniqueFileName)
            
            var mediaType: MediaType
            switch resource.type {
            case .pairedVideo:
                mediaType = .video
            case .photo:
                mediaType = .photo
            default:
                printDebug("Error, could not handle media type \(resource.type)")
                continue
            }
            
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: fileURL, options: options)
            // Only the still-photo component carries the name — it drives the
            // group's metadata, and the paired video must not overwrite it.
            let media = CleartextMedia(
                source: fileURL,
                mediaType: mediaType,
                id: id,
                originalFilename: resource.type == .photo ? resource.originalFilename : nil
            )
            cleartextMediaArray.append(media)
        }
        
        return cleartextMediaArray
    }
    
    /// Forwards a `Progress`'s fraction until the returned observation is invalidated.
    private static func forward(_ loadProgress: Progress, to progress: @escaping @Sendable (Double) -> Void) -> NSKeyValueObservation {
        loadProgress.observe(\.fractionCompleted, options: [.new]) { observed, _ in
            progress(observed.fractionCompleted)
        }
    }

    private func ensureTempDirectoryExists() async throws {
        if tempDirectoryChecked { return }
        
        let tempDir = URL.tempMediaDirectory
        var isDirectory: ObjCBool = false
        
        if !FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            printDebug("🗂️ Created temp directory: \(tempDir.path)")
        } else {
            printDebug("🗂️ Temp directory already exists: \(tempDir.path)")
        }
        
        tempDirectoryChecked = true
    }
    
    /// Logs media loading errors with detailed information
    private func logMediaLoadError(_ error: Error, for result: MediaSelectionResult) {
        let identifier: String
        switch result {
        case .phAsset(let asset): identifier = asset.localIdentifier
        case .phPickerResult(let picker): identifier = picker.assetIdentifier ?? "unknown"
        }
        
        printDebug("❌ Error loading media \(identifier): \(error)")
        if let nsError = error as NSError? {
            printDebug("❌ Error domain: \(nsError.domain), code: \(nsError.code)")
        }
    }
}
