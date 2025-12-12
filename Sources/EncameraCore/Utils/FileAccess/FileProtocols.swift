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

public protocol FileEnumerator {

    func configure(for album: Album, albumManager: AlbumManaging) async
    func enumerateMedia<T: MediaDescribing>() async -> [InteractableMedia<T>]
}

public protocol FileReader: FileEnumerator {
    
    func configure(for album: Album, albumManager: AlbumManaging) async
    func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)?) async throws -> UIImage?
    func loadMediaPreview<T: MediaDescribing>(for media: InteractableMedia<T>) async throws -> PreviewModel
    func loadMedia<T: MediaDescribing>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia>
}

public protocol FileWriter: FileEnumerator {
        
    @discardableResult func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>?
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
extension FileWriter {
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
