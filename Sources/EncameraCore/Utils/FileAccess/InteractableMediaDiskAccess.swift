//  Created by Alexander Freas on 17.07.24.
//

import Foundation
import UIKit

public actor InteractableMediaDiskAccess: FileAccess {
    public init() {
        fileAccess = DiskFileAccess()
    }


    private var fileAccess: DiskFileAccess
    private var album: Album?
    private var albumManager: AlbumManaging?

    // MARK: - Media Index state

    private var directoryModel: DataStorageModel?
    private var indexStore: MediaIndexStore?
    /// In-memory snapshot of the album's media index, loaded lazily.
    private var cachedIndex: MediaIndex?
    /// Timestamp when `cachedIndex` was last written (locally or from disk).
    private var cacheTimestamp: Date?

    public init(for album: Album, albumManager: AlbumManaging) async {
        self.fileAccess = DiskFileAccess()
        await configure(for: album, albumManager: albumManager)
    }


    public func configure(for album: Album, albumManager: AlbumManaging) async {
        let albumChanged = self.album?.id != album.id
        await fileAccess.configure(for: album, albumManager: albumManager)
        self.album = album
        self.albumManager = albumManager
        self.directoryModel = albumManager.storageModel(for: album)
        // Only reset the index when switching albums — re-configuring for the
        // same album (e.g. a gallery refresh) keeps the warm in-memory cache.
        if albumChanged {
            self.indexStore = MediaIndexStore(album: album)
            self.cachedIndex = nil
            self.cacheTimestamp = nil
        }
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
    
    /// Enumerates media with sorting and filtering support
    /// Groups related media (e.g., Live Photo photo + video) into InteractableMedia wrappers
    /// - Parameters:
    ///   - sortBy: How to sort results (default: dateEncrypted descending)
    ///   - filterBy: Media subtypes to include (default: all)
    /// - Returns: Array of MediaWithMetadata containing grouped InteractableMedia and extracted metadata
    public func enumerateMediaWithMetadata(
        sortBy sortOption: MediaSortOption = .dateEncrypted(ascending: false),
        filterBy filterOptions: MediaFilterOptions = .all
    ) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] {
        
        // Get raw encrypted media with metadata from DiskFileAccess
        let rawMediaWithMetadata = await fileAccess.enumerateEncryptedMediaWithMetadata(
            sortBy: sortOption,
            filterBy: filterOptions
        )
        
        // Group by media ID (for Live Photos which have photo + video components)
        // We need to preserve the order while grouping
        var mediaMap: [String: (interactable: InteractableMedia<EncryptedMedia>, metadata: EncryptedFileMetadata?, dateTaken: Date?, dateEncrypted: Date?, subtype: MediaFilterOptions)] = [:]
        var orderedIds: [String] = []
        
        for item in rawMediaWithMetadata {
            let mediaId = item.media.id
            
            if var existing = mediaMap[mediaId] {
                // Add to existing group (e.g., video component of Live Photo)
                existing.interactable.appendToUnderlyingMedia(media: item.media)
                mediaMap[mediaId] = existing
            } else {
                // Create new group
                do {
                    let interactable = try InteractableMedia(underlyingMedia: [item.media])
                    mediaMap[mediaId] = (
                        interactable: interactable,
                        metadata: item.metadata,
                        dateTaken: item.dateTaken,
                        dateEncrypted: item.dateEncrypted,
                        subtype: item.mediaSubtype
                    )
                    orderedIds.append(mediaId)
                } catch {
                    debugPrint("Could not create interactable media: \(error)")
                }
            }
        }
        
        // Build result array preserving order
        var results: [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] = []
        
        for mediaId in orderedIds {
            guard let group = mediaMap[mediaId] else { continue }
            
            // For Live Photos, treat as still images for filtering purposes
            var subtype = group.subtype
            if group.interactable.mediaType == .livePhoto {
                subtype = .stillImage
            }
            
            let wrapper = MediaWithMetadata(
                media: group.interactable,
                metadata: group.metadata,
                dateTaken: group.dateTaken,
                dateEncrypted: group.dateEncrypted,
                mediaSubtype: subtype
            )
            results.append(wrapper)
        }
        
        return results
    }

    public func loadLeadingThumbnail(purchasedPermissions: (any PurchasedPermissionManaging)?) async throws -> UIImage? {
        // Check if album cover is explicitly disabled

        if let album = album,
           let albumManager = albumManager {
            // Cover is disabled, skip cover image check and go to permission-based logic
            guard let purchasedPermissions = purchasedPermissions else {
                return nil
            }
            if albumManager.isAlbumCoverImageDisabled(album: album) {
                return nil
            }

            if albumManager.getAlbumCoverImageId(album: album) != nil {
                return try await fileAccess.loadLeadingThumbnail()
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
            // Check for cancellation before loading each media item
            try Task.checkCancellation()
            
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
            // Check for cancellation before decrypting each media item
            try Task.checkCancellation()
            
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
        return try await save(media: media, metadata: nil, progress: progress)
    }
    
    public func save(media: InteractableMedia<CleartextMedia>, metadata: EncryptedFileMetadata?, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        var encrypted: [EncryptedMedia] = []
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before processing each media item
            // This ensures cancellation propagates through the actor boundary
            try Task.checkCancellation()
            if let encryptedMedia = try await fileAccess.save(media: mediaItem, metadata: metadata, progress: progress) {
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
            // Check for cancellation before copying each media item
            try Task.checkCancellation()
            try await fileAccess.copy(media: mediaItem)
        }
    }
    
    public func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        for mediaItem in media.underlyingMedia {
            // Check for cancellation before moving each media item
            try Task.checkCancellation()
            try await fileAccess.move(media: mediaItem, progress: progress)
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
    
    public func totalStoredMediaCount() async -> Int {
        return await fileAccess.totalStoredMediaCount()
    }

    // MARK: - Media Index

    /// Returns the in-memory index, loading it from disk on first access or
    /// when the on-disk file is newer than the cached copy (e.g. after a
    /// migration rebuild on a separate actor). Returns `nil` if no index has
    /// been built yet — building is the job of `reconcileIndex()`.
    private func cachedOrLoadedIndex() async -> MediaIndex? {
        if cachedIndex != nil, let store = indexStore {
            let diskDate = store.fileModificationDate()
            if let diskDate, let cacheDate = cacheTimestamp, diskDate > cacheDate {
                if let reloaded = await store.load() {
                    cachedIndex = reloaded
                    cacheTimestamp = diskDate
                    return reloaded
                }
            }
            return cachedIndex
        }
        if let loaded = await indexStore?.load() {
            cachedIndex = loaded
            // Use the index file's modification date — not `Date()` — so
            // `reconcileIndex` correctly flags any file edits that happened
            // between the index save and this load as in-place modifications.
            cacheTimestamp = indexStore?.fileModificationDate() ?? Date()
            return loaded
        }
        return nil
    }

    /// Rebuilds the index from scratch by reconciling against an empty index —
    /// every file on disk is treated as new and has its metadata read. Used by
    /// the startup migration.
    /// - Parameter onProgress: Optional `(filesRead, totalFiles)` callback for
    ///   reporting how far the rebuild has progressed.
    @discardableResult
    public func rebuildIndex(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> MediaIndex {
        cachedIndex = MediaIndex(entries: [])
        await reconcileIndex(onProgress: onProgress)
        return await cachedOrLoadedIndex() ?? MediaIndex(entries: [])
    }

    /// Brings the index in sync with the album's files. Lists the directory by
    /// name only (no `stat`, no decryption), then incrementally drops entries
    /// for removed files and reads metadata for *only* the newly-added files —
    /// so this stays cheap even on a large album. Returns whether the index
    /// changed.
    /// - Parameter onProgress: Optional `(filesRead, totalFiles)` callback that
    ///   fires while metadata is read for added/modified files.
    @discardableResult
    public func reconcileIndex(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> Bool {
        let diskURLsByID = currentMediaURLsByID()
        let diskIDs = Set(diskURLsByID.keys)
        let existingEntries = (await cachedOrLoadedIndex())?.entries ?? []
        let indexIDs = Set(existingEntries.map { $0.id })

        let removedIDs = indexIDs.subtracting(diskIDs)
        let addedIDs = diskIDs.subtracting(indexIDs)

        // Detect in-place modifications for entries whose IDs still match.
        let modifiedIDs: Set<String>
        if let cacheDate = cacheTimestamp {
            let unchanged = indexIDs.intersection(diskIDs)
            modifiedIDs = Self.idsModifiedSince(cacheDate, among: unchanged, urlsByID: diskURLsByID)
        } else {
            modifiedIDs = []
        }

        guard !removedIDs.isEmpty || !addedIDs.isEmpty || !modifiedIDs.isEmpty else {
            return false
        }

        var entries = existingEntries.filter {
            !removedIDs.contains($0.id) && !modifiedIDs.contains($0.id)
        }

        let idsToRead = addedIDs.union(modifiedIDs)
        if !idsToRead.isEmpty {
            let mediaToRead: [EncryptedMedia] = idsToRead.flatMap { id in
                (diskURLsByID[id] ?? []).compactMap {
                    EncryptedMedia(source: .url($0), generateID: false)
                }
            }
            let withMetadata = await fileAccess.encryptedMediaWithMetadata(
                for: mediaToRead,
                onProgress: onProgress
            )
            entries.append(contentsOf: Self.makeEntries(fromFileLevelMetadata: withMetadata))
        }

        let updated = MediaIndex(entries: entries)
        do {
            try await indexStore?.save(updated)
        } catch {
            debugPrint("[InteractableMediaDiskAccess] failed to persist reconciled index: \(error)")
            return false
        }
        cachedIndex = updated
        cacheTimestamp = indexStore?.fileModificationDate() ?? Date()
        return true
    }

    /// Produces a page of media from the index. Pure in-memory work: filter and
    /// sort the cached entries, then materialize the slice into `InteractableMedia`
    /// without touching the filesystem or decrypting anything. Returns an empty
    /// page if no index has been built yet — `reconcileIndex()` will build one.
    public func mediaPage(
        sortBy sortOption: MediaSortOption,
        filterBy filterOptions: MediaFilterOptions,
        offset: Int,
        pageSize: Int
    ) async -> MediaPageResult {
        guard let index = await cachedOrLoadedIndex() else {
            return MediaPageResult(media: [], totalCount: 0, nextOffset: 0)
        }
        /* begin fault injection hook */
        // UI-test fault injection: widens the per-page window so a test can
        // interleave a UI action between page loads. Inert in production.
        let delayMs = MediaIndexTestHooks.pageLoadDelayMs
        if delayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
        /* end fault injection hook */
        let sorted = index.sortedFilteredEntries(sortBy: sortOption, filterBy: filterOptions)
        let start = max(0, min(offset, sorted.count))
        let limit = max(0, pageSize)
        var media: [InteractableMedia<EncryptedMedia>] = []
        var cursor = start
        while media.count < limit, cursor < sorted.count {
            if let item = materialize(sorted[cursor]) {
                media.append(item)
            }
            cursor += 1
        }
        return MediaPageResult(media: media, totalCount: sorted.count, nextOffset: cursor)
    }

    /// Removes the given media ids from the index — a cheap incremental patch
    /// for deletes and moves that avoids a full rebuild.
    public func removeFromIndex(ids: Set<String>) async {
        guard !ids.isEmpty, var index = await cachedOrLoadedIndex() else {
            return
        }
        let originalCount = index.entries.count
        index.entries.removeAll { ids.contains($0.id) }
        guard index.entries.count != originalCount else {
            return
        }
        do {
            try await indexStore?.save(index)
        } catch {
            debugPrint("[InteractableMediaDiskAccess] failed to persist index after removal: \(error)")
            return
        }
        cachedIndex = index
        cacheTimestamp = indexStore?.fileModificationDate() ?? Date()
    }

    // MARK: - Media Index helpers

    /// Builds an `InteractableMedia` for an index entry by reconstructing its
    /// file URLs — no filesystem read, no decryption.
    private func materialize(_ entry: MediaIndexEntry) -> InteractableMedia<EncryptedMedia>? {
        /* begin fault injection hook */
        let stride = MediaIndexTestHooks.failMaterializeStride
        if stride > 0, abs(entry.id.hashValue) % stride == 0 {
            return nil
        }
        /* end fault injection hook */
        guard let directoryModel else { return nil }
        var underlying: [EncryptedMedia] = []
        if entry.hasPhotoComponent {
            let url = directoryModel.driveURLForMedia(withID: entry.id, type: .photo)
            underlying.append(EncryptedMedia(source: .url(url), mediaType: .photo, id: entry.id))
        }
        if entry.hasVideoComponent {
            let url = directoryModel.driveURLForMedia(withID: entry.id, type: .video)
            underlying.append(EncryptedMedia(source: .url(url), mediaType: .video, id: entry.id))
        }
        guard !underlying.isEmpty else { return nil }
        return try? InteractableMedia(underlyingMedia: underlying)
    }

    /// Returns IDs whose files on disk have a modification date newer than the
    /// given reference date — a lightweight way to detect in-place edits.
    static func idsModifiedSince(
        _ referenceDate: Date,
        among ids: Set<String>,
        urlsByID: [String: [URL]]
    ) -> Set<String> {
        var modified = Set<String>()
        for id in ids {
            guard let urls = urlsByID[id] else { continue }
            for url in urls {
                if let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate > referenceDate {
                    modified.insert(id)
                    break
                }
            }
        }
        return modified
    }

    /// Media file URLs currently on disk, grouped by media id, from a cheap
    /// directory listing. The modification date is prefetched so the reconcile's
    /// in-place-edit check reads it from cache rather than issuing a fresh
    /// `stat` per file.
    ///
    /// iCloud placeholder stubs (`.<id>.<encext>.icloud`) ARE included here
    /// even though their last path extension is `icloud`: the enumerator
    /// matches on the middle extension (see
    /// `DataStorageModel.enumeratorForStorageDirectory`) precisely so
    /// `undownloadedMediaCount` can detect them via `pathExtension == "icloud"`.
    private func currentMediaURLsByID() -> [String: [URL]] {
        guard let directoryModel else { return [:] }
        let urls = directoryModel.enumeratorForStorageDirectory(
            resourceKeys: [.contentModificationDateKey],
            fileExtensionFilter: [
                MediaType.photo.encryptedFileExtension,
                MediaType.video.encryptedFileExtension
            ]
        )
        var grouped: [String: [URL]] = [:]
        for url in urls {
            guard let id = EncryptedMedia(source: .url(url), generateID: false)?.id else { continue }
            grouped[id, default: []].append(url)
        }
        return grouped
    }

    /// Number of media items in the album not yet downloaded from iCloud, from
    /// a cheap name-only directory scan — iCloud placeholders carry a `.icloud`
    /// path extension. Counts unique media ids across the whole album,
    /// independent of which pages the gallery has loaded.
    public func undownloadedMediaCount() -> Int {
        currentMediaURLsByID().values.reduce(into: 0) { count, urls in
            if urls.contains(where: { $0.pathExtension == "icloud" }) {
                count += 1
            }
        }
    }

    /// Groups file-level metadata by media id (a Live Photo's photo and video
    /// components share an id) into one `MediaIndexEntry` per id.
    private static func makeEntries(
        fromFileLevelMetadata items: [MediaWithMetadata<EncryptedMedia>]
    ) -> [MediaIndexEntry] {
        var groupsByID: [String: [MediaWithMetadata<EncryptedMedia>]] = [:]
        var idOrder: [String] = []
        for item in items {
            if groupsByID[item.media.id] == nil {
                idOrder.append(item.media.id)
            }
            groupsByID[item.media.id, default: []].append(item)
        }

        return idOrder.compactMap { id in
            guard let group = groupsByID[id], let primary = group.first else { return nil }
            let types = Set(group.map { $0.media.mediaType })
            // Prefer the photo component's metadata; fall back to the first.
            let representative = group.first { $0.media.mediaType == .photo } ?? primary
            return MediaIndexEntry(
                id: id,
                hasPhotoComponent: types.contains(.photo),
                hasVideoComponent: types.contains(.video),
                dateEncrypted: representative.dateEncrypted,
                dateTaken: representative.dateTaken,
                subtypeRawValue: representative.mediaSubtype.rawValue
            )
        }
    }

    public static func deleteThumbnailDirectory() throws {
        try DiskFileAccess.deleteThumbnailDirectory()
    }

    // MARK: - Test hooks

    /// Test-only: wire an explicit `MediaIndexStore` so a test can exercise
    /// load behavior without a full `Album` + `AlbumManaging` graph.
    internal func _testSetIndexStore(_ store: MediaIndexStore) {
        self.indexStore = store
    }

    /// Test-only: forces a load from disk via `cachedOrLoadedIndex` and
    /// returns the `cacheTimestamp` that was recorded.
    internal func _testLoadAndReadCacheTimestamp() async -> Date? {
        _ = await cachedOrLoadedIndex()
        return cacheTimestamp
    }

    /// Test-only: returns the current in-memory `cachedIndex` so a test
    /// can verify it is or isn't rolled back after a save failure.
    internal func _testReadCachedIndex() -> MediaIndex? {
        cachedIndex
    }
}


