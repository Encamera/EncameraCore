//
//  FileProtocols.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine

enum StorageType: String {
    case icloud
    case local
    
    enum Availability {
        case available
        case unavailable(reason: String)
    }
    
    var modelForType: DataStorageModel.Type {
        switch self {
        case .icloud:
            return iCloudStorageModel.self
        case .local:
            return LocalStorageModel.self
        }
    }
    
}

extension StorageType: Identifiable, CaseIterable {
    var id: Self { self }
    var title: String {
        switch self {
        case .icloud:
            return "iCloud"
        case .local:
            return "Local"
        }
    }
    
    var iconName: String {
        switch self {
        case .icloud:
            return "lock.icloud"
        case .local:
            return "lock.iphone"
        }
    }
    
    var description: String {
        switch self {
        case .icloud:
            return "Saves encrypted files to iCloud Drive."
        case .local:
            return "Saves encrypted files to this device."
        }
    }
    
}
protocol DataStorageModel {
    var baseURL: URL { get }
    var keyName: KeyName { get }
    var thumbnailDirectory: URL { get }
    
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
}

protocol FileEnumerator {
        
    init(key: ImageKey, storageSettingsManager: DataStorageSetting)
    func enumerateMedia<T: MediaDescribing>() async -> [T] where T.MediaSource == URL
}

protocol FileReader {
    
    init(key: ImageKey, storageSettingsManager: DataStorageSetting)
    func loadMediaPreview<T: MediaDescribing>(for media: T) async throws -> PreviewModel where T.MediaSource == URL
    func loadMediaToURL<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<URL>
    func loadMediaInMemory<T: MediaDescribing>(media: T, progress: @escaping (Double) -> Void) async throws -> CleartextMedia<Data>
}

protocol FileWriter {
        
    @discardableResult func save<T: MediaSourcing>(media: CleartextMedia<T>) async throws -> EncryptedMedia
    @discardableResult func saveThumbnail<T: MediaDescribing>(data: Data, sourceMedia: T) async throws -> CleartextMedia<Data>
    @discardableResult func savePreview<T: MediaDescribing>(preview: PreviewModel, sourceMedia: T) async throws -> CleartextMedia<Data>
    func delete(media: EncryptedMedia) async throws
}

protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init(key: ImageKey, storageSettingsManager: DataStorageSetting)
}
