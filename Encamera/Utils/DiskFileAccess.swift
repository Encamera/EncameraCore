//
//  iCloudFilesManager.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import Foundation
import UIKit
import Combine
import AVFoundation

actor DiskFileAccess: FileEnumerator {
    
    enum iCloudError: Error {
        case invalidURL
        case general
    }
    var key: ImageKey
        
    private var cancellables = Set<AnyCancellable>()
    private let directoryModel: DataStorageModel
    init(key: ImageKey, storageSettingsManager: DataStorageSetting) {
        self.key = key
        let storageModel = storageSettingsManager.storageModelFor(keyName: key.name)
        self.directoryModel =  storageModel
        try! self.directoryModel.initializeDirectories()
    }
    
    func enumerateMedia<T>() async -> [T] where T : MediaDescribing, T.MediaSource == URL { // this is not truly async, should be though
        
        let driveUrl = directoryModel.baseURL
        _ = driveUrl.startAccessingSecurityScopedResource()
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])
        
        guard let enumerator = FileManager.default.enumerator(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys)) else {
            return []
        }
        
        let imageItems: [T] = enumerator.compactMap { item in
            guard let itemUrl = item as? URL else {
                return nil
            }
            return itemUrl
        }.filter({
            let components = $0.lastPathComponent.split(separator: ".")
            let fileExtensions = components[(components.count-2)...]
            
            return fileExtensions.joined(separator: ".") == [MediaType.photo.fileExtension, AppConstants.fileExtension].joined(separator: ".")
        })
            .sorted { (url1: URL, url2: URL) in
                guard let resourceValues1 = try? url1.resourceValues(forKeys: resourceKeys),
                      let creationDate1 = resourceValues1.creationDate,
                      let resourceValues2 = try? url2.resourceValues(forKeys: resourceKeys),
                      let creationDate2 = resourceValues2.creationDate else {
                    return false
                }
                return creationDate1.compare(creationDate2) == .orderedDescending
            }.compactMap { (itemUrl: URL) in
                return T(source: itemUrl)
            }
        driveUrl.stopAccessingSecurityScopedResource()
        return imageItems
    }
    
}

extension DiskFileAccess: FileReader {
    
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL {
        
        let thumbnailPath = directoryModel.previewURLForMedia(media)
        let preview = T(source: thumbnailPath, mediaType: .preview, id: media.id)
        
        do {
            let existingPreview = try await loadMediaInMemory(media: preview) { _ in }
            return PreviewModel(source: existingPreview)
        } catch {
            return try await self.createPreview(for: media)
        }
    }
    
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: (Double) -> Void) async throws -> CleartextMedia<Data> {
        
        if let encrypted = media as? EncryptedMedia {
            return try await decryptMedia(encrypted: encrypted, progress: progress)
        } else {
            fatalError()
        }
    }
    
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL> {
        if let encrypted = media as? EncryptedMedia {
             return try await decryptMedia(encrypted: encrypted, progress: progress)
        } else if let cleartext = media as? CleartextMedia<URL> {
            return cleartext
        }
        
        fatalError()
    }
    private func decryptMedia(encrypted: EncryptedMedia, progress: (Double) -> Void) async throws -> CleartextMedia<Data> {
        
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: encrypted)
        
        let decrypted: CleartextMedia<Data> = try await fileHandler.decrypt()
        sourceURL.stopAccessingSecurityScopedResource()
        return decrypted
    }
    
    private func decryptMedia(encrypted: EncryptedMedia, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL> {
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: encrypted)
        fileHandler.progress
            .receive(on: DispatchQueue.main)
            .sink { percent in
            progress(percent)
        }.store(in: &cancellables)
        let decrypted: CleartextMedia<URL> = try await fileHandler.decrypt()
        sourceURL.stopAccessingSecurityScopedResource()
        return decrypted
    }
    private func generateThumbnailFromVideo(at path: URL) -> UIImage? {
        do {
            let asset = AVURLAsset(url: path, options: nil)
            let imgGenerator = AVAssetImageGenerator(asset: asset)
            imgGenerator.appliesPreferredTrackTransform = true
            let cgImage = try imgGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil)
            
            let thumbnail = UIImage(cgImage: cgImage)
            return thumbnail
        } catch let error {
            debugPrint("*** Error generating thumbnail: \(error.localizedDescription)")
            return nil
        }
    }
    
    @discardableResult private func createPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel {
        
        let thumbnail = try await createThumbnail(for: media)
        var preview = PreviewModel(thumbnailMedia: thumbnail)
        if let encrypted = media as? EncryptedMedia {
            switch encrypted.mediaType {
            case .photo:
                break
            case .video:
                let video: CleartextMedia<URL> = try await decryptMedia(encrypted: encrypted, progress: {_ in })
                let asset = AVURLAsset(url: video.source, options: nil)
                preview.videoDuration = asset.duration.durationText
            default:
                throw SecretFilesError.createPreviewError
            }
        } else if let decrypted = media as? CleartextMedia<URL>, decrypted.mediaType == .video {
            let asset = AVURLAsset(url: decrypted.source, options: nil)
            preview.videoDuration = asset.duration.durationText
        }
        try await savePreview(preview: preview, sourceMedia: media)
        
        return preview
    }

    @discardableResult private func createThumbnail<T: MediaDescribing>(for media: T) async throws -> CleartextMedia<Data> {
        
        
        var thumbnailSourceData: Data
        if let encrypted = media as? EncryptedMedia {
            
            switch encrypted.mediaType {
                
            case .photo:
                let decrypted: CleartextMedia<Data> = try await self.decryptMedia(encrypted: encrypted) { _ in }
                thumbnailSourceData = decrypted.source
                
            case .video:
                let decrypted: CleartextMedia<URL> = try await self.decryptMedia(encrypted: encrypted) { _ in }
                guard let thumb = self.generateThumbnailFromVideo(at: decrypted.source),
                      let data = thumb.pngData() else {
                    throw SecretFilesError.createVideoThumbnailError
                }
                thumbnailSourceData = data
                try decrypted.delete()
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let cleartext = media as? CleartextMedia<URL> {
            switch cleartext.mediaType {
            case .photo:
                thumbnailSourceData = try Data(contentsOf: cleartext.source)
            case .video:
                guard let thumb = self.generateThumbnailFromVideo(at: cleartext.source),
                      let data = thumb.pngData() else {
                    throw SecretFilesError.createVideoThumbnailError
                }
                thumbnailSourceData = data
            default:
                throw SecretFilesError.fileTypeError
            }
        } else if let cleartext = media as? CleartextMedia<Data> {
            switch cleartext.mediaType {
            case .photo:
                thumbnailSourceData = cleartext.source
            default:
                throw SecretFilesError.fileTypeError
            }
        } else {
            fatalError()
        }
        let resizer = ImageResizer(targetWidth: 50)
        guard let thumbnailData = resizer.resize(data: thumbnailSourceData)?.pngData() else {
            fatalError()
        }

        
        let cleartextThumb = CleartextMedia(source: thumbnailData, mediaType: .thumbnail, id: media.id)
        return cleartextThumb
        
    }
}

extension DiskFileAccess: FileWriter {
    
    @discardableResult func saveThumbnail<T: MediaDescribing>(data: Data, sourceMedia: T) async throws -> CleartextMedia<Data> {
        let destinationURL = directoryModel.thumbnailURLForMedia(sourceMedia)
        let cleartextThumb = CleartextMedia(source: data, mediaType: .thumbnail, id: sourceMedia.id)

        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartextThumb, targetURL: destinationURL)
        try await fileHandler.encrypt()
        return cleartextThumb
    }
    
    @discardableResult func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data> {
        let data = try JSONEncoder().encode(preview)
        let destinationURL = directoryModel.previewURLForMedia(sourceMedia)
        let cleartextPreview = CleartextMedia(source: data, mediaType: .preview, id: sourceMedia.id)

        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartextPreview, targetURL: destinationURL)
        try await fileHandler.encrypt()
        return cleartextPreview
    }
    
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia {
        let destinationURL = directoryModel.driveURLForNewMedia(media)
        let fileHandler = SecretFileHandler(keyBytes: key.keyBytes, source: media, targetURL: destinationURL)
        let encrypted = try await fileHandler.encrypt()
        try await createPreview(for: media)
        try media.delete()
        return encrypted
    }
    
    func delete(media: EncryptedMedia) async throws {
        
        try FileManager.default.removeItem(at: media.source)
        try FileManager.default.removeItem(at: media.thumbnailURL)
        
    }
}

extension DiskFileAccess: FileAccess {
    
}

extension UIImage {
    func scalePreservingAspectRatio(targetSize: CGSize) -> UIImage {
        // Determine the scale factor that preserves aspect ratio
        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height
        
        let scaleFactor = min(widthRatio, heightRatio)
        
        // Compute the new image size that preserves aspect ratio
        let scaledImageSize = CGSize(
            width: size.width * scaleFactor,
            height: size.height * scaleFactor
        )
        
        // Draw and return the resized UIImage
        let renderer = UIGraphicsImageRenderer(
            size: scaledImageSize
        )
        
        let scaledImage = renderer.image { _ in
            self.draw(in: CGRect(
                origin: .zero,
                size: scaledImageSize
            ))
        }
        
        return scaledImage
    }
}
