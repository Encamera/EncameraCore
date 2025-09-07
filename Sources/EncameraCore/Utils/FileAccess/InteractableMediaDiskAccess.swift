//  Created by Alexander Freas on 17.07.24.
//

import Foundation
import UIKit

public actor InteractableMediaDiskAccess: FileAccess {
    public init() {
        fileAccess = DiskFileAccess()
    }


    private var fileAccess: DiskFileAccess

    public init(for album: Album, albumManager: AlbumManaging) async {
        await self.fileAccess = DiskFileAccess(for: album, albumManager: albumManager)
    }


    public func configure(for album: Album, albumManager: AlbumManaging) async {
        await fileAccess.configure(for: album, albumManager: albumManager)
    }
    
    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T : MediaDescribing {
        let media: [T] = await fileAccess.enumerateMedia()

        var mediaMap = [String: InteractableMedia<T>]()

        for mediaItem in media {
            do {
                if let interactableMedia = mediaMap[mediaItem.id] {
                    interactableMedia.appendToUnderlyingMedia(media: mediaItem)
                    continue
                } else {
                    let interactableMedia = try InteractableMedia(underlyingMedia: [mediaItem])
                    mediaMap[interactableMedia.id] = interactableMedia
                }
            } catch {
                debugPrint("Could not create interactable media: \(error)")
            }
        }
        let sortedByDateDesc = Array(mediaMap.values).sorted { media1, media2 in
            guard let timestamp1 = media1.timestamp, let timestamp2 = media2.timestamp else {
                return false
            }
            return timestamp1.compare(timestamp2) == .orderedDescending
        }
        return sortedByDateDesc
    }
    




    public func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)?) async throws -> UIImage? {
        // Always check for album cover image first (same logic as DiskFileAccess)
        // This delegates to the underlying fileAccess which has access to album and directoryModel
        if let coverThumbnail = try await fileAccess.loadLeadingThumbnail(purchasedPermissions: nil) {
            return coverThumbnail
        }
        
        // If no cover image is set and we have permissions, use permission-based logic
        guard let purchasedPermissions = purchasedPermissions else {
            // If no permissions and no cover image, return nil
            return nil
        }
        
        // Get all media properly grouped as InteractableMedia (like the gallery does)
        let media: [InteractableMedia<EncryptedMedia>] = await enumerateMedia()
        guard !media.isEmpty else {
            return nil
        }
        
        // Find the last accessible photo (similar to blurItemAt logic)
        let totalCount = media.count
        
        // Start from the most recent photo (index 0) and find the first one we can access
        for index in 0..<totalCount {
            let accessCount = Double(totalCount - index)
            if purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: accessCount)) {
                // This is the most recent photo we can access, use it as the leading thumbnail
                let targetMedia = media[index]
                do {
                    let cleartextPreview = try await fileAccess.loadMediaPreview(for: targetMedia.thumbnailSource)
                    guard let previewData = cleartextPreview.thumbnailMedia.data, 
                          let thumbnail = UIImage(data: previewData) else {
                        continue // Try next photo if thumbnail generation fails
                    }
                    return thumbnail
                } catch {
                    continue // Try next photo if preview loading fails
                }
            }
        }
        
        // If we can't access any photos, return nil
        return nil
    }
    
    public func loadMediaPreview<T>(for media: InteractableMedia<T>) async throws -> PreviewModel where T : MediaDescribing {
        var preview = try await fileAccess.loadMediaPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    public func loadMediaToURLs(
        media: InteractableMedia<EncryptedMedia>,
        progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL] {
        var urls = [URL]()
        for mediaItem in media.underlyingMedia {

            let loaded = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
            guard let url = loaded.url else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T : MediaDescribing {


        var decrypted: [CleartextMedia] = []
        for mediaItem in media.underlyingMedia {
            if mediaItem.mediaType == .photo {
                let cleartextMedia = try await fileAccess.loadMediaInMemory(media: mediaItem, progress: progress)
                decrypted.append(cleartextMedia)
            } else if mediaItem.mediaType == .video {

                let cleartextMedia = try await fileAccess.loadMediaToURL(media: mediaItem, progress: progress)
                decrypted.append(cleartextMedia)
            }
        }
        progress(.loaded)
        return try InteractableMedia(underlyingMedia: decrypted)

    }
    

    public func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        var encrypted: [EncryptedMedia] = []
        for mediaItem in media.underlyingMedia {
            if let encryptedMedia = try await fileAccess.save(media: mediaItem, progress: progress) {
                encrypted.append(encryptedMedia)
            }
        }

        return try InteractableMedia(underlyingMedia: encrypted)
    }
    
    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        var preview = try await fileAccess.createPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }
    
    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        for mediaItem in media.underlyingMedia {
            try await fileAccess.copy(media: mediaItem)
        }
    }
    
    public func move(media: InteractableMedia<EncryptedMedia>) async throws {
        for mediaItem in media.underlyingMedia {
            try await fileAccess.move(media: mediaItem)
        }
    }
    
    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        let allMediaItems = media.flatMap { $0.underlyingMedia }
        try await fileAccess.delete(media: allMediaItems)
    }
    
    public func deleteMediaForKey() async throws {
        try await fileAccess.deleteMediaForKey()
    }
        
    public func deleteAllMedia() async throws {
        try await fileAccess.deleteAllMedia()
    }
    
    public func setKeyUUIDForExistingFiles() async throws {
        try await fileAccess.setKeyUUIDForExistingFiles()
    }
    
    public static func deleteThumbnailDirectory() throws {
        try DiskFileAccess.deleteThumbnailDirectory()
    }
}


