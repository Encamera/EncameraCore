//
//  FileProtocols.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine
import UIKit

public enum FileAccessError: Error, ErrorDescribable {
    case missingDirectoryModel
    case missingPrivateKey
    case missingKeyManager
    case unhandledMediaType
    case couldNotLoadMedia
    case iCloudFileNotDownloaded(status: iCloudFileStatus)
    case iCloudDownloadFailed(status: iCloudFileStatus)
    case iCloudDownloadInProgress(status: iCloudFileStatus)
    case iCloudDownloadTimeout
    
    public var displayDescription: String {
        switch self {
        case .missingDirectoryModel:
            return "Missing directory model"
        case .missingPrivateKey:
            return L10n.noKeyAvailable
        case .missingKeyManager:
            return "Missing key manager"
        case .unhandledMediaType:
            return "Unhandled media type"
        case .couldNotLoadMedia:
            return "Could not load media"
        case .iCloudFileNotDownloaded(let status):
            return iCloudFileStatusUtil.userFriendlyErrorMessage(for: status)
        case .iCloudDownloadFailed(let status):
            return iCloudFileStatusUtil.userFriendlyErrorMessage(for: status)
        case .iCloudDownloadInProgress(let status):
            return iCloudFileStatusUtil.userFriendlyErrorMessage(for: status)
        case .iCloudDownloadTimeout:
            return L10n.ICloudError.downloadTimeout
        }
    }
}

public enum FileLoadingStatus {
    case notLoaded
    case downloading(progress: Double)
    case decrypting(progress: Double)
    case loaded
}

// MARK: - Sorting & Filtering Types

/// Sort options for media enumeration
public enum MediaSortOption: Sendable {
    case dateTaken(ascending: Bool)
    case dateEncrypted(ascending: Bool)
}

/// Filter options for media subtypes (OptionSet for multi-select)
public struct MediaFilterOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    
    public static let video = MediaFilterOptions(rawValue: 1 << 0)
    public static let livePhoto = MediaFilterOptions(rawValue: 1 << 1)
    public static let screenshot = MediaFilterOptions(rawValue: 1 << 2)
    public static let stillImage = MediaFilterOptions(rawValue: 1 << 3)
    
    public static let all: MediaFilterOptions = [.video, .livePhoto, .screenshot, .stillImage]
    public static let allPhotos: MediaFilterOptions = [.livePhoto, .screenshot, .stillImage]
}

/// Wrapper that pairs media with its metadata for sorted/filtered results
/// Generic over T to support both EncryptedMedia and InteractableMedia<EncryptedMedia>
public struct MediaWithMetadata<T> {
    public let media: T
    public let metadata: EncryptedFileMetadata?
    public let dateTaken: Date?
    public let dateEncrypted: Date?
    public let mediaSubtype: MediaFilterOptions
    
    public init(media: T, metadata: EncryptedFileMetadata?,
                dateTaken: Date?, dateEncrypted: Date?,
                mediaSubtype: MediaFilterOptions) {
        self.media = media
        self.metadata = metadata
        self.dateTaken = dateTaken
        self.dateEncrypted = dateEncrypted
        self.mediaSubtype = mediaSubtype
    }
}

public protocol FileEnumerator {

    func configure(for album: Album, albumManager: AlbumManaging) async
    func enumerateMedia<T: MediaDescribing>() async -> [InteractableMedia<T>]
    
    /// Enumerates media with sorting and filtering support
    /// - Parameters:
    ///   - sortBy: How to sort results
    ///   - filterBy: Media subtypes to include
    /// - Returns: Array of MediaWithMetadata containing media and extracted metadata
    func enumerateMediaWithMetadata(
        sortBy: MediaSortOption,
        filterBy: MediaFilterOptions
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>]
}

// Default implementation for backwards compatibility
public extension FileEnumerator {
    func enumerateMediaWithMetadata(
        sortBy: MediaSortOption = .dateEncrypted(ascending: false),
        filterBy: MediaFilterOptions = .all
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] {
        return [] // Default empty - concrete types implement
    }
}

public protocol FileReader: FileEnumerator {
    
    func configure(for album: Album, albumManager: AlbumManaging) async
    func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)?) async throws -> UIImage?
    func loadMediaPreview<T: MediaDescribing>(for media: InteractableMedia<T>) async throws -> PreviewModel
    func loadMedia<T: MediaDescribing>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia>
}

public protocol FileWriter: FileEnumerator {
        
    @discardableResult func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>?
    @discardableResult func save(media: InteractableMedia<CleartextMedia>, metadata: EncryptedFileMetadata?, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>?
    @discardableResult func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel
    func copy(media: InteractableMedia<EncryptedMedia>) async throws
    func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)?) async throws
    func delete(media: [InteractableMedia<EncryptedMedia>]) async throws
    func deleteMediaForKey() async throws
    func deleteAllMedia() async throws
    func setKeyUUIDForExistingFiles() async throws
    static func deleteThumbnailDirectory() throws
}

// Default implementation for backwards compatibility
public extension FileWriter {
    func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        return try await save(media: media, metadata: nil, progress: progress)
    }
}

// Default implementation for backwards compatibility
public extension FileWriter {
    func move(media: InteractableMedia<EncryptedMedia>) async throws {
        try await move(media: media, progress: nil)
    }
}

public protocol FileAccess: FileEnumerator, FileReader, FileWriter {
    init()
    init(for album: Album, albumManager: AlbumManaging) async
    func loadMediaToURLs(
        media: InteractableMedia<EncryptedMedia>,
        progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL]
}

extension FileAccess {
    var operationBus: FileOperationBus {
        FileOperationBus.shared
    }
}
