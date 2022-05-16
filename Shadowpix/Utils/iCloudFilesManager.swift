//
//  iCloudFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import Foundation
import UIKit
import Combine

struct iCloudFilesManager {
    private static var cancellables = Set<AnyCancellable>()

    static func getImageAt(url imageUrl: URL) -> DecryptedImage? {
        guard imageUrl.lastPathComponent.contains(".live") == false else {
            return nil
        }
        
        do {
            _ = imageUrl.startAccessingSecurityScopedResource()
            let data = try Data(contentsOf: imageUrl)
            imageUrl.stopAccessingSecurityScopedResource()
            guard let decrypted: UIImage = ChaChaPolyHelpers.decrypt(encryptedContent: data) else {
                print("Could not decrypt image")
                return nil
            }
            return DecryptedImage(image: decrypted)

        } catch {
            print("error opening image", error.localizedDescription)
            return nil
        }

    }
    
    private static func driveUrl(for key: ImageKey) -> URL {
        guard let driveURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") else {
            fatalError("Could not get drive url")
        }
        
        let destURL = driveURL.appendingPathComponent(key.name)
        try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: false, attributes: nil)
        return destURL
    }
    
    static func encryptAndMoveToiCloudDrive(sourceUrl: URL, photoId: String, isLivePhoto: Bool = false) {
        
        guard let photoData = try? Data(contentsOf: sourceUrl) else {
            fatalError("Could not get data from url")
        }
        saveEncryptedToiCloudDrive(photoData, photoId: photoId)
    }
    
    static func saveEncryptedToiCloudDrive(_ photoData: Data, photoId: String, isLivePhoto: Bool = false) {
        

        guard let encrypted = ChaChaPolyHelpers.encrypt(contentData: photoData) else {
            fatalError("Could not encrypt image")
        }
        guard let key = ShadowPixState.shared.selectedKey else {
            fatalError("No key stored")
        }
        
        let driveUrl = driveUrl(for: key)
            
        let imageUrl = driveUrl.appendingPathComponent("\(photoId)\(isLivePhoto ? ".live" : "").shdwpic")

        do {
            
            try encrypted.write(to: imageUrl)
        } catch {
            print(error)
            fatalError("Could not write to drive url")
        }
    }


}

protocol FileEnumerator {
    func enumerateImages(directoryModel: iCloudFilesDirectoryModel, completion: ([ShadowPixMedia]) -> Void)
}

protocol DirectoryModel {
    var driveURL: URL { get }
}

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

struct iCloudFilesEnumerator: FileEnumerator {
        
    func enumerateImages(directoryModel: iCloudFilesDirectoryModel, completion: ([ShadowPixMedia]) -> Void) {
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
