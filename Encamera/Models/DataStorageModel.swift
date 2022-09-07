//
//  DataStorageModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation

protocol DataStorageModel {
    var baseURL: URL { get }
    var keyName: KeyName { get }
    var thumbnailDirectory: URL { get }
    var storageType: StorageType { get }
    
    init(keyName: KeyName)
    func initializeDirectories() throws
    
}

extension DataStorageModel {
    
    var thumbnailDirectory: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let thumbnailDirectory = documentsDirectory.appendingPathComponent("thumbs")
        return thumbnailDirectory
    }
    
    func initializeDirectories() throws {
        if FileManager.default.fileExists(atPath: thumbnailDirectory.path) == false {
            try FileManager.default.createDirectory(atPath: thumbnailDirectory.path, withIntermediateDirectories: true)
        }
        
        if FileManager.default.fileExists(atPath: baseURL.path) == false {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    func driveURLForNewMedia<T: MediaDescribing>(_ media: T) -> URL {
        let filename = "\(media.id).\(media.mediaType.fileExtension).\(AppConstants.fileExtension)"
        return baseURL.appendingPathComponent(filename)
    }
    
    func thumbnailFor<T: MediaDescribing>(media: T) -> EncryptedMedia {
        let thumbnailURL = thumbnailURLForMedia(media)
        let media = EncryptedMedia(source: thumbnailURL, mediaType: .thumbnail, id: media.id)
        return media
    }
    
    func thumbnailURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(media.mediaType.fileExtension).\(MediaType.thumbnail.fileExtension)")
        return thumbnailPath
    }
    
    func previewURLForMedia<T: MediaDescribing>(_ media: T) -> URL {
        let thumbnailPath = thumbnailDirectory.appendingPathComponent("\(media.id).\(media.mediaType.fileExtension).\(MediaType.preview.fileExtension)")
        return thumbnailPath
    }
    
    func enumeratorForStorageDirectory(resourceKeys: Set<URLResourceKey>) -> [URL] {
        let driveUrl = baseURL
        _ = driveUrl.startAccessingSecurityScopedResource()
        
        guard let enumerator = FileManager.default.enumerator(at: driveUrl, includingPropertiesForKeys: Array(resourceKeys)) else {
            return []
        }
        driveUrl.stopAccessingSecurityScopedResource()
        return enumerator.compactMap { item in
            guard let itemUrl = item as? URL else {
                return nil
            }
            return itemUrl
        }.filter({
            let components = $0.lastPathComponent.split(separator: ".")
            guard components.count > 1 else {
                return false
            }
            let fileExtensions = components[(components.count-2)...]
            return fileExtensions.joined(separator: ".") == [MediaType.photo.fileExtension, AppConstants.fileExtension].joined(separator: ".")
        })
    }
    
    func countOfFiles() -> Int {
        return enumeratorForStorageDirectory(resourceKeys: Set()).count
    }
}
