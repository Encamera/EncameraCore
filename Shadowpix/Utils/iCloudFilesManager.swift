//
//  iCloudFilesManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import Foundation
import UIKit

struct iCloudFilesManager {
    
    static func getImageAt(url imageUrl: URL) -> UIImage? {
        do {
            _ = imageUrl.startAccessingSecurityScopedResource()
            let data = try Data(contentsOf: imageUrl)
            imageUrl.stopAccessingSecurityScopedResource()
            guard let decrypted: UIImage = ChaChaPolyHelpers.decrypt(encryptedContent: data) else {
                print("Could not decrypt image")
                return nil
            }
            return decrypted

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
    
    static func saveEncryptedToiCloudDrive(_ photoData: Data, photoId: String, isLivePhoto: Bool = false) {
        
        

        guard let encrypted = ChaChaPolyHelpers.encrypt(contentData: photoData) else {
            fatalError("Could not encrypt image")
        }
        guard let key = ShadowPixState.shared.selectedKey else {
            fatalError("No key stored")
        }
        
        let driveUrl = driveUrl(for: key)
            
        let imageUrl = driveUrl.appendingPathComponent("\(isLivePhoto ? ".live" : "").shdwpic")

        do {
            
            try encrypted.write(to: imageUrl)
            try ShadowPixState.shared.tempFilesManager.cleanup()
        } catch {
            print(error)
            fatalError("Could not write to drive url")
        }
    }

    static func enumerateImagesFor(key: ImageKey) {
        do {
            let driveUrl = driveUrl(for: key)
            guard driveUrl.startAccessingSecurityScopedResource() else {
                fatalError("Could not access security scoped resource")
            }
            
            let enumerator = FileManager.default.enumerator(atPath: driveUrl.absoluteString)
            
            enumerator?.forEach({ file in
                print(file)
            })
            
        } catch {
            
        }
    }
}
