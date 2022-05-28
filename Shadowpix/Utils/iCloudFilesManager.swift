//
//  iCloudFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import Foundation
import UIKit
import Combine

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
        try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: false, attributes: nil)
        return destURL
    }
}

class iCloudFilesEnumerator: FileEnumerator {
    
    enum iCloudError: Error {
        case invalidURL
        case general
    }
    
    var directoryModel: DirectoryModel
    var key: ImageKey!
    private var cancellables: [AnyCancellable] = []
    
    required init(directoryModel: DirectoryModel, key: ImageKey?) {
        self.directoryModel = directoryModel
        self.key = key
    }
        func enumerateMedia(completion: ([ShadowPixMedia]) -> Void) {
        let driveUrl = directoryModel.driveURL
        _ = driveUrl.startAccessingSecurityScopedResource()
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])
        
        guard let enumerator = FileManager.default.enumerator(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys)) else {
            return
        }
        
        let imageItems: [ShadowPixMedia] = enumerator.compactMap { item in
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
                return ShadowPixMedia(url: itemUrl)
            }
        completion(imageItems)
        driveUrl.stopAccessingSecurityScopedResource()
        
    }

}

extension iCloudFilesEnumerator: FileReader {
    func loadMedia(media: MediaDescribing) -> AnyPublisher<CleartextMedia, Never> {
        if let encrypted = media as? EncryptedMedia {
            
        return decryptMedia(encrypted: encrypted).replaceError(with: CleartextMedia(mediaType: .unknown)).eraseToAnyPublisher()
        } else {
            fatalError()
        }
    }
    
    
    func loadMediaPreview(for media: ShadowPixMedia) {
        
        //make this actually scale down the image
//        getMediaAt(url: media.url).sink { completion in
//
//        } receiveValue: { value in
//            media.decryptedImage = value
//        }.store(in: &cancellables)

    }

    
    private func decryptMedia(encrypted: EncryptedMedia) -> AnyPublisher<CleartextMedia, Error> {
        guard let sourceURL = encrypted.sourceURL else {
            return Fail(error: iCloudError.invalidURL)
                .eraseToAnyPublisher()
        }
        _ = sourceURL.startAccessingSecurityScopedResource()
        return SecretInMemoryFileHander(sourceMedia: encrypted, keyBytes: key.keyBytes).decryptInMemory().mapError({ error in
            iCloudError.general
        }).eraseToAnyPublisher()
    }
}

extension iCloudFilesEnumerator: FileWriter {
    
    func save(media: CleartextMedia) -> AnyPublisher<EncryptedMedia, Error> {
        let tempURL = TempFilesManager.createTempURL(media: media)
        let fileHandler = SecretDiskFileHandler(keyBytes: key.keyBytes, source: media, destinationURL: tempURL)
        return Future { [weak self] completion in
            guard let self = self else { return }
            fileHandler.encryptFile().sink { fileCompletion in

                switch fileCompletion {

                case .finished:
                    break
                case .failure(let error):
                    completion(.failure(error))
                }
            } receiveValue: { encrypted in
                completion(.success(encrypted))
            }.store(in: &self.cancellables)
        }.eraseToAnyPublisher()

    }
    
    

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
            _ = driveUrl.startAccessingSecurityScopedResource()
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
