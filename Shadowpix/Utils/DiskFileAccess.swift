//
//  iCloudFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import Foundation
import UIKit
import Combine
import AVFoundation

struct iCloudFilesDirectoryModel: DirectoryModel {
    let subdirectory: String
    let keyName: String
    
    var driveURL: URL {
        guard let driveURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") else {
            fatalError("Could not get drive url")
        }
        
        let destURL = driveURL.appendingPathComponent(keyName)
            .appendingPathComponent(subdirectory)
        do {
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("could not create directory \(error.localizedDescription)")
        }
        return destURL
    }
    
    
}

class DiskFileAccess<D: DirectoryModel>: FileEnumerator {
    
    enum iCloudError: Error {
        case invalidURL
        case general
    }
    var key: ImageKey!
    private var cancellables: [AnyCancellable] = []
    
    required init(key: ImageKey?) {
        self.key = key
    }
    
    func enumerateMedia<T>(for directory: DirectoryModel) async -> [T] where T : MediaDescribing, T.MediaSource == URL { // this is not truly async, should be though
        
        let driveUrl = directory.driveURL
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
        }
            .sorted { (url1: URL, url2: URL) in
                guard let resourceValues1 = try? url1.resourceValues(forKeys: resourceKeys),
                      let creationDate1 = resourceValues1.creationDate,
                      let resourceValues2 = try? url2.resourceValues(forKeys: resourceKeys),
                      let creationDate2 = resourceValues2.creationDate else {
                    return false
                }
                return creationDate1.compare(creationDate2) == .orderedDescending
            }.compactMap { (itemUrl: URL) in
                print(itemUrl)
                return T(source: itemUrl)
            }
        print(imageItems.map({$0.mediaType}))
        driveUrl.stopAccessingSecurityScopedResource()
        return imageItems
    }
    
}

extension DiskFileAccess: FileReader {
    
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> CleartextMedia<Data> where T.MediaSource == URL {
            
            let thumbnailPath = try D(subdirectory: media.mediaType.path, keyName: key.name).thumbnailURLForMedia(media)
            let thumb = T(source: thumbnailPath, mediaType: .thumbnail, id: media.id)
            
        do {
            let existingThumb = try await loadMediaInMemory(media: thumb)
            return existingThumb
        } catch {
            return try await self.createThumbnail(for: media)
        }
    }
    
    func loadMediaInMemory<T>(media: T) async throws -> CleartextMedia<Data> where T : MediaDescribing {
        
        if let encrypted = media as? EncryptedMedia {
            return try await decryptMedia(encrypted: encrypted)
        } else {
            fatalError()
        }
    }
    func loadMediaToURL<T>(media: T) async throws -> CleartextMedia<URL> where T : MediaDescribing {
        if let encrypted = media as? EncryptedMedia {
             return try await decryptMedia(encrypted: encrypted)
        } else if let cleartext = media as? CleartextMedia<URL> {
            return cleartext
        }
        
        fatalError()
    }
    private func decryptMedia(encrypted: EncryptedMedia) async throws -> CleartextMedia<Data> {
        
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        let decrypted = try await SecretInMemoryFileHander(sourceMedia: encrypted, keyBytes: key.keyBytes).decryptInMemory()
        sourceURL.stopAccessingSecurityScopedResource()
        return decrypted
    }
    
    private func decryptMedia(encrypted: EncryptedMedia) async throws -> CleartextMedia<URL> {
        
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        let decrypted = try await SecretDiskFileHandler(keyBytes: self.key.keyBytes, source: encrypted).decryptFile()
        sourceURL.stopAccessingSecurityScopedResource()
        return decrypted
        
    }
    func generateThumbnailFromVideo(at path: URL) -> UIImage? {
        do {
            let asset = AVURLAsset(url: path, options: nil)
            let imgGenerator = AVAssetImageGenerator(asset: asset)
            imgGenerator.appliesPreferredTrackTransform = true
            let cgImage = try imgGenerator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil)
            
            let thumbnail = UIImage(cgImage: cgImage)
            return thumbnail
        } catch let error {
            print("*** Error generating thumbnail: \(error.localizedDescription)")
            return nil
        }
    }

    private func createThumbnail<T: MediaDescribing>(for media: T) async throws -> CleartextMedia<Data> {
        guard let encrypted = media as? EncryptedMedia else {
            throw SecretFilesError.createThumbnailError
        }
        
        var thumbnailData: Data
            switch encrypted.mediaType {
                
            case .photo:
                let decrypted: CleartextMedia<Data> = try await self.decryptMedia(encrypted: encrypted)
                let resizer = ImageResizer(targetWidth: 50)
                guard let data = resizer.resize(data: decrypted.source)?.pngData() else {
                    fatalError()
                }
                thumbnailData = data
                
            case .video:
                let decrypted: CleartextMedia<URL> = try await self.decryptMedia(encrypted: encrypted)
                guard let thumb = self.generateThumbnailFromVideo(at: decrypted.source),
                      let data = thumb.pngData() else {
                    fatalError()
                }
                thumbnailData = data
            case .thumbnail, .unknown:
                fatalError()
            }
        
        let cleartextThumb = CleartextMedia(source: thumbnailData, mediaType: .thumbnail, id: encrypted.id)
        try await self.saveThumbnail(media: cleartextThumb)
        return cleartextThumb
        
    }
}

extension DiskFileAccess: FileWriter {
    
    @discardableResult func saveThumbnail(media: CleartextMedia<Data>) async throws -> EncryptedMedia {
        let destinationURL = try D(subdirectory: media.mediaType.path, keyName: key.name).thumbnailURLForMedia(media)
        let fileHandler = SecretDiskFileHandler(keyBytes: key.keyBytes, source: media, destinationURL: destinationURL)
        return try await fileHandler.encryptFile()

    }
    
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia {
        let destinationURL = D(subdirectory: media.mediaType.path, keyName: key.name).driveURLForNewMedia(media)
        let fileHandler = SecretDiskFileHandler(keyBytes: key.keyBytes, source: media, destinationURL: destinationURL)
        return try await fileHandler.encryptFile()
        
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

class iCloudFilesSubscription<S: Subscriber>: Subscription where S.Input == [URL], S.Failure == Error {
    
    enum iCloudFilesError: Error {
        case createEnumeratorFailed
    }
    
    private let driveUrl: URL
    private var subscriber: S?
    
    init(driveUrl: URL, subscriber: S) {
        self.driveUrl = driveUrl
        self.subscriber = subscriber
    }
    
    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }
        
        do {
            let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])
            
            guard let enumerator = FileManager.default.enumerator(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys)) else {
                throw iCloudFilesError.createEnumeratorFailed
            }
            
            let imageItems: [URL] = enumerator.compactMap { item in
                guard let itemUrl = item as? URL else {
                    return nil
                }
                return itemUrl
            }.sorted { (url1: URL, url2: URL) in
                guard let resourceValues1 = try? url1.resourceValues(forKeys: resourceKeys),
                      let creationDate1 = resourceValues1.creationDate,
                      let resourceValues2 = try? url2.resourceValues(forKeys: resourceKeys),
                      let creationDate2 = resourceValues2.creationDate else {
                    return false
                }
                return creationDate1.compare(creationDate2) == .orderedDescending
            }
            let newDemand = subscriber?.receive(imageItems)
            print(newDemand!)
            subscriber?.receive(completion: .finished)
        } catch let error {
            subscriber?.receive(completion: .failure(error))
            
        }
    }
    
    func cancel() {
        subscriber = nil
    }
    
}

struct iCloudFilesPublisher: Publisher {
    
    typealias Output = [URL]
    typealias Failure = Error
    
    let driveURL: URL
    
    func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, [URL] == S.Input {
        
        let subscription = iCloudFilesSubscription(driveUrl: driveURL, subscriber: subscriber)
        
        subscriber.receive(subscription: subscription)
    }
}
