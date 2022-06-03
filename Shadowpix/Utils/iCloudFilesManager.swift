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
    
    func driveURLForNewMedia<T: MediaSourcing>(_ media: CleartextMedia<T>) -> URL {
        let filename = "\(NSUUID().uuidString).\(media.mediaType.fileExtension)"
        return driveURL.appendingPathComponent(filename)
    }
}

class iCloudFilesEnumerator: FileEnumerator {
    
    enum iCloudError: Error {
        case invalidURL
        case general
    }
    var key: ImageKey!
    private var cancellables: [AnyCancellable] = []
    private var tempFileManager: TempFilesManager

    required init(key: ImageKey?) {
        self.key = key
        self.tempFileManager = TempFilesManager.shared
    }
    
    func enumerateMedia<T: MediaDescribing>(for directory: DirectoryModel, completion: ([T]) -> Void) where T.MediaSource == URL  {
        let driveUrl = directory.driveURL
        _ = driveUrl.startAccessingSecurityScopedResource()
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .creationDateKey])
        
        guard let enumerator = FileManager.default.enumerator(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys)) else {
            return
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
        completion(imageItems)
        driveUrl.stopAccessingSecurityScopedResource()
        
    }

}

extension iCloudFilesEnumerator: FileReader {
   
    func loadMediaPreview<T: MediaDescribing>(for media: T) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError> {
        return loadMedia(media: media)
    }
    
    func loadMedia<T: MediaDescribing>(media: T) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError> {
        if let encrypted = media as? EncryptedMedia {
            
            return decryptMedia(encrypted: encrypted).eraseToAnyPublisher()
        } else {
            fatalError()
        }
    }
    
    func loadMedia<T: MediaDescribing>(media: T) -> AnyPublisher<CleartextMedia<URL>, SecretFilesError> {
        if let encrypted = media as? EncryptedMedia {
            let decryptedPublisher = decryptMedia(encrypted: encrypted) as AnyPublisher<CleartextMedia<URL>, SecretFilesError>
            return decryptedPublisher.eraseToAnyPublisher()
        } else if let cleartext = media as? CleartextMedia<URL> {
            return Just(cleartext).setFailureType(to: SecretFilesError.self).eraseToAnyPublisher()
        }
        
        fatalError()
    }
    private func decryptMedia(encrypted: EncryptedMedia) -> AnyPublisher<CleartextMedia<Data>, SecretFilesError> {
        
        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        return SecretInMemoryFileHander(sourceMedia: encrypted, keyBytes: key.keyBytes).decryptInMemory()
        
    }
    
    private func decryptMedia(encrypted: EncryptedMedia) -> AnyPublisher<CleartextMedia<URL>, SecretFilesError> {

        let sourceURL = encrypted.source
        
        _ = sourceURL.startAccessingSecurityScopedResource()
        return Future { completion in
            SecretDiskFileHandler(keyBytes: self.key.keyBytes, source: encrypted).decryptFile()
                .sink(receiveCompletion: { signal in
                    
            sourceURL.stopAccessingSecurityScopedResource()
                    switch signal {
                        
                    case .finished:
                        break
                    case .failure(let error):
                        completion(.failure(error))
                    }
                    
        }, receiveValue: { url in
            completion(.success(url))
        }).store(in: &self.cancellables)
            
        }.eraseToAnyPublisher()
    }
}

extension iCloudFilesEnumerator: FileWriter {
    
    func createTempURL(for mediaType: MediaType) -> URL {
        tempFileManager.createTempURL(for: mediaType)
    }
    
    func save<T: MediaSourcing>(media: CleartextMedia<T>) -> AnyPublisher<EncryptedMedia, SecretFilesError> {
        
        let destinationURL = iCloudFilesDirectoryModel(subdirectory: media.mediaType.path, keyName: key.name).driveURLForNewMedia(media)
        let fileHandler = SecretDiskFileHandler(keyBytes: key.keyBytes, source: media, destinationURL: destinationURL)
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

extension iCloudFilesEnumerator: FileAccess {
    
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
