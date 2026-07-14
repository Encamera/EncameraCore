//
//  CloudKitFileAccess.swift
//  EncameraCore
//
//  The CloudKit branch of the app's file access. Reuses the EXISTING crypto
//  (`SecretFileHandlerV2`) and preview pipeline (`DiskFileAccess.createPreview`)
//  unchanged — only the transport differs (decision doc §6). Save encrypts then
//  uploads; load lazily fetches the blob then decrypts; enumeration comes from the
//  coordinator's synced `MediaIndexStore`; delete tombstones+purges across devices.
//  `InteractableMediaFileAccess` routes here for `.cloudKit` albums behind the flag.
//

import Foundation
import UIKit

/// Supplies the `CloudKitMediaStoring` implementation. Production returns the real
/// store; UI tests bind a deterministic in-memory mock via `UITestSupport`.
public enum CloudKitStoreProvider {
    /// `tokenNamespace` scopes the store's zone change-token cursor per album so
    /// albums don't clobber each other's sync position. Mocks may ignore it.
    nonisolated(unsafe) public static var makeStore: @Sendable (_ tokenNamespace: String) -> CloudKitMediaStoring = { namespace in
        CloudKitMediaStore(tokenNamespace: namespace)
    }
}

public actor CloudKitFileAccess: MediaBackend {

    private let album: Album
    private let albumIDHash: String
    private let keyBytes: [UInt8]
    private let store: CloudKitMediaStoring
    private let coordinator: CloudKitSyncCoordinator
    private let directoryModel: DataStorageModel
    private let indexStore: MediaIndexStore
    /// Reused solely for the existing preview-generation pipeline.
    private let previewAccess: DiskFileAccess
    /// Change tag the local thumbnail file was fetched for, so a remote re-upload
    /// (new tag) forces a refresh instead of showing stale content. Persisted as a
    /// sidecar next to the album's blob cache: the facade constructs a fresh
    /// instance on every album switch while the coordinator's tag map is shared
    /// via the registry, so a purely in-memory map would treat every revisit as a
    /// mismatch — deleting good previews and re-downloading every visible
    /// thumbnail (and, offline, leaving them blank).
    private var thumbnailTags: [String: String] = [:]
    private var thumbnailTagsLoaded = false

    private var thumbnailTagsURL: URL {
        directoryModel.baseURL.appendingPathComponent(".thumbtags.json")
    }

    private func loadThumbnailTagsIfNeeded() {
        guard !thumbnailTagsLoaded else { return }
        thumbnailTagsLoaded = true
        guard let data = try? Data(contentsOf: thumbnailTagsURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        thumbnailTags = decoded
    }

    private func setThumbnailTag(_ tag: String?, for id: String) {
        loadThumbnailTagsIfNeeded()
        thumbnailTags[id] = tag
        // Written only after a fetch attempt, so the album demonstrably exists —
        // creating the cache directory here cannot confuse `AlbumManager.create`'s
        // existence check (see `CloudKitStorageModel.baseURL`).
        guard let data = try? JSONEncoder().encode(thumbnailTags) else { return }
        try? FileManager.default.createDirectory(at: directoryModel.baseURL, withIntermediateDirectories: true)
        try? data.write(to: thumbnailTagsURL, options: .atomic)
    }

    public init(album: Album, albumManager: AlbumManaging, store: CloudKitMediaStoring? = nil) async {
        self.album = album
        self.keyBytes = album.key.keyBytes
        let albumIDHash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) ?? album.id
        self.albumIDHash = albumIDHash
        let resolvedStore = store ?? CloudKitStoreProvider.makeStore(albumIDHash)
        self.store = resolvedStore
        self.directoryModel = CloudKitStorageModel(album: album)
        let index = MediaIndexStore(album: album)
        self.indexStore = index
        if store != nil {
            // Explicit store (tests): own coordinator + fresh cache, fully isolated.
            self.coordinator = CloudKitSyncCoordinator(albumID: albumIDHash,
                                                       store: resolvedStore,
                                                       cache: CloudKitBlobCache(),
                                                       indexStore: index)
        } else {
            // Production: share ONE coordinator per album so the active album and the
            // push fan-out keep the same in-memory state.
            self.coordinator = await CloudKitCoordinatorRegistry.shared.coordinator(forAlbumID: albumIDHash) {
                CloudKitSyncCoordinator(albumID: albumIDHash,
                                        store: resolvedStore,
                                        cache: CloudKitBlobCache.shared,
                                        indexStore: index)
            }
        }
        let preview = DiskFileAccess()
        await preview.configure(for: album, albumManager: albumManager)
        self.previewAccess = preview
    }

    // MARK: - Configure

    /// `MediaBackend` conformance. A `CloudKitFileAccess` is bound to its album at
    /// `init` (it derives `albumIDHash`, the store, and the coordinator there), so
    /// the facade constructs a fresh instance per album rather than re-pointing an
    /// existing one. This is a no-op kept only to satisfy the protocol; the warm-up
    /// is driven by `start()`, which the facade calls after construction.
    public func configure(for album: Album, albumManager: AlbumManaging) async {
        // Intentionally empty — see doc comment above.
    }

    // MARK: - Lifecycle

    /// Ensures the custom zone exists, registers the push subscription, and does an
    /// initial delta sync. Safe to call repeatedly; no-ops when the account is
    /// unavailable. Push-driven re-sync is handled app-wide by `CloudKitAlbumsSync`
    /// (which covers inactive albums too), not per-instance here.
    public func start() async {
        if await store.accountAvailable() {
            try? await store.ensureZoneExists()   // routed through the store; mocks no-op
        }
        await coordinator.startObserving()
        try? await coordinator.sync(albumID: albumIDHash)
    }

    // MARK: - Save (encrypt then upload)

    public func save(media: InteractableMedia<CleartextMedia>,
                     metadata: EncryptedFileMetadata?,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        // The custom zone must exist before records target it — `start()` runs in a
        // detached task, so an early capture can't assume it finished. Idempotent.
        if await store.accountAvailable() {
            try? await store.ensureZoneExists()
        }
        var encrypted: [EncryptedMedia] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let encMedia = try await saveSingle(item, metadata: metadata, progress: progress)
            encrypted.append(encMedia)
        }
        guard !encrypted.isEmpty else { return nil }
        return try InteractableMedia(underlyingMedia: encrypted)
    }

    /// A unique CloudKit record name per media component. Photo and video
    /// components of a Live Photo share `mediaID` but must be distinct records.
    static func componentRecordName(mediaID: String, type: MediaType) -> String {
        "\(mediaID)#\(type.rawValue)"
    }

    private func saveSingle(_ item: CleartextMedia,
                            metadata: EncryptedFileMetadata?,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> EncryptedMedia {
        let encURL = directoryModel.driveURLForMedia(withID: item.id, type: item.mediaType)
        try FileManager.default.createDirectory(at: directoryModel.baseURL, withIntermediateDirectories: true)

        // 1. Encrypt with the existing V2 handler — only ciphertext leaves the device.
        let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: item, targetURL: encURL)
        _ = try await handler.encryptWithMetadata(metadata ?? EncryptedFileMetadata())

        // 2. Generate + persist the encrypted preview via the existing pipeline. Only
        // attach the thumbnail if the file actually exists — a failed preview must not
        // make the whole record's asset save fail.
        _ = try? await previewAccess.createPreview(for: item)
        let previewURL = directoryModel.previewURLForMedia(withID: item.id)
        let thumbURL = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil

        // 3. Upload the single Option-A record (index fields + thumbnail + blob).
        let size = (try? FileManager.default.attributesOfItem(atPath: encURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let upload = CloudKitMediaUpload(
            albumID: albumIDHash,
            mediaID: item.id,
            mediaType: item.mediaType,
            createdAt: metadata?.primaryDate ?? Date(),
            sizeBytes: size,
            encryptedFileURL: encURL,
            encryptedThumbURL: thumbURL,
            recordName: Self.componentRecordName(mediaID: item.id, type: item.mediaType)
        )
        do {
            _ = try await coordinator.upload(upload, progress: progress)
        } catch CloudKitMediaStoreError.zoneNotFound {
            // The zone was removed server-side but our flag said it existed. Recreate
            // it and retry the upload once.
            try await store.recreateZone()
            _ = try await coordinator.upload(upload, progress: progress)
        }
        return EncryptedMedia(source: .url(encURL), mediaType: item.mediaType, id: item.id)
    }

    // MARK: - Load (lazy fetch then decrypt)

    public func loadMedia(media: InteractableMedia<some MediaDescribing>,
                          progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        var decrypted: [CleartextMedia] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let local = try await ensureLocalCiphertext(id: item.id, type: item.mediaType, progress: progress)
            progress(.decrypting(progress: 0))
            let encMedia = EncryptedMedia(source: .url(local), mediaType: item.mediaType, id: item.id)
            let cleartext: CleartextMedia
            if item.mediaType == .photo {
                let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: encMedia)
                cleartext = try await handler.decryptInMemory()
            } else {
                let target = URL.tempMediaDirectory.appendingPathComponent("\(item.id).\(item.mediaType.decryptedFileExtension)")
                let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: encMedia, targetURL: target)
                cleartext = try await handler.decryptToURL()
            }
            decrypted.append(cleartext)
        }
        progress(.loaded)
        return try InteractableMedia(underlyingMedia: decrypted)
    }

    public func loadMediaToURLs(media: InteractableMedia<EncryptedMedia>,
                                progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> [URL] {
        var urls: [URL] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let local = try await ensureLocalCiphertext(id: item.id, type: item.mediaType, progress: progress)
            progress(.decrypting(progress: 0))
            let encMedia = EncryptedMedia(source: .url(local), mediaType: item.mediaType, id: item.id)
            let target = URL.tempMediaDirectory.appendingPathComponent("\(item.id).\(item.mediaType.decryptedFileExtension)")
            let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: encMedia, targetURL: target)
            let cleartext = try await handler.decryptToURL()
            if let url = cleartext.url { urls.append(url) }
        }
        progress(.loaded)
        return urls
    }

    /// Resolves the current encrypted blob for `id` via the coordinator's
    /// change-tag-aware cache: a server-side re-upload (new tag) invalidates the
    /// stale copy and refetches, so we never decrypt outdated content. We decrypt
    /// directly from the cache URL rather than keeping a separate untracked copy.
    private func ensureLocalCiphertext(id: String,
                                       type: MediaType,
                                       progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> URL {
        let recordName = Self.componentRecordName(mediaID: id, type: type)
        progress(.downloading(progress: 0))
        return try await coordinator.ensureBlobLocal(recordName: recordName, albumID: albumIDHash) { fraction in
            progress(.downloading(progress: fraction))
        }
    }

    // MARK: - Previews

    public func loadMediaPreview(for media: InteractableMedia<some MediaDescribing>) async throws -> PreviewModel {
        let source = media.thumbnailSource!
        let previewURL = directoryModel.previewURLForMedia(withID: source.id)
        let recordName = Self.componentRecordName(mediaID: source.id, type: source.mediaType)
        let currentTag = await coordinator.currentChangeTag(recordName: recordName)
        loadThumbnailTagsIfNeeded()
        // Refetch the eager thumbnail if it's missing OR a KNOWN server tag differs
        // from the tag the local copy was fetched for (a remote re-upload). A nil
        // `currentTag` means "no newer tag observed yet" (fresh coordinator before
        // its first delta sync) — trust the local file, mirroring the blob cache.
        let stale = currentTag != nil && thumbnailTags[source.id] != currentTag
        if !FileManager.default.fileExists(atPath: previewURL.path) || stale {
            try? FileManager.default.removeItem(at: previewURL)
            do {
                try await store.fetchThumbnail(recordName: recordName, to: previewURL)
                // Only record the tag on a SUCCESSFUL fetch — otherwise a failed fetch
                // would mark the (missing/partial) thumbnail as current and never retry.
                setThumbnailTag(currentTag, for: source.id)
            } catch {
                setThumbnailTag(nil, for: source.id)
            }
        }
        var preview = try await previewAccess.loadMediaPreview(for: source)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        var preview = try await previewAccess.createPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    // MARK: - Delete (tombstone + cross-device purge)

    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        for interactable in media {
            for item in interactable.underlyingMedia {
                let recordName = Self.componentRecordName(mediaID: item.id, type: item.mediaType)
                try await coordinator.remove(recordName: recordName, albumID: albumIDHash)
                let localURL = directoryModel.driveURLForMedia(withID: item.id, type: item.mediaType)
                try? FileManager.default.removeItem(at: localURL)
            }
        }
    }

    // MARK: - Enumeration (from the synced index, never the network)

    /// Brings the local index in sync with CloudKit (delta fetch).
    @discardableResult
    public func reconcile() async -> Bool {
        do {
            try await coordinator.sync(albumID: albumIDHash)
            return true
        } catch {
            return false
        }
    }

    /// Sorted/filtered metadata enumeration from the synced index (never the network).
    public func enumerateMediaWithMetadata(sortBy sortOption: MediaSortOption,
                                           filterBy filterOptions: MediaFilterOptions) async -> [MediaWithMetadata<InteractableMedia<EncryptedMedia>>] {
        let index = await indexStore.current() ?? MediaIndex(entries: [])
        return index.sortedFilteredEntries(sortBy: sortOption, filterBy: filterOptions).compactMap { entry in
            guard let media = materialize(entry) else { return nil }
            return MediaWithMetadata(media: media,
                                     metadata: nil,
                                     dateTaken: entry.dateTaken,
                                     dateEncrypted: entry.dateEncrypted,
                                     mediaSubtype: MediaFilterOptions(rawValue: entry.subtypeRawValue))
        }
    }

    /// Removes every item in the album from CloudKit (tombstone + purge) and the index.
    public func deleteAllMedia() async throws {
        let all = await enumerate()
        guard !all.isEmpty else { return }
        try await delete(media: all)
    }

    public func enumerate() async -> [InteractableMedia<EncryptedMedia>] {
        let entries = (await indexStore.current())?.entries ?? []
        return entries.compactMap { materialize($0) }.sorted {
            guard let a = $0.timestamp, let b = $1.timestamp else { return false }
            return a > b
        }
    }

    /// `FileEnumerator` conformance. CloudKit only ever produces
    /// `InteractableMedia<EncryptedMedia>`; the generic cast keeps the facade from
    /// having to special-case the backend.
    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T: MediaDescribing {
        (await enumerate()) as? [InteractableMedia<T>] ?? []
    }

    public func totalStoredMediaCount() async -> Int {
        (await indexStore.current())?.entries.count ?? 0
    }

    private func materialize(_ entry: MediaIndexEntry) -> InteractableMedia<EncryptedMedia>? {
        var underlying: [EncryptedMedia] = []
        if entry.hasPhotoComponent {
            underlying.append(EncryptedMedia(source: .url(cacheURL(id: entry.id, type: .photo)), mediaType: .photo, id: entry.id))
        }
        if entry.hasVideoComponent {
            underlying.append(EncryptedMedia(source: .url(cacheURL(id: entry.id, type: .video)), mediaType: .video, id: entry.id))
        }
        guard !underlying.isEmpty else { return nil }
        return try? InteractableMedia(underlyingMedia: underlying)
    }

    /// The on-disk path where a lazily-downloaded blob actually lands (the blob cache
    /// keys by record name). `EncryptedMedia.source` must point here — not at the
    /// `id.ext` path — so source-readers find the file after a download.
    private func cacheURL(id: String, type: MediaType) -> URL {
        directoryModel.baseURL.appendingPathComponent(Self.componentRecordName(mediaID: id, type: type))
    }

    // MARK: - Diagnostics (iCloud Flight Check)

    /// Drops the cached ciphertext for a component so the next `loadMedia` is forced
    /// to re-download it from CloudKit — proving the blob is durable server-side
    /// rather than being served from the copy the upload cached locally.
    public func evictCachedBlob(for id: String, type: MediaType) async throws {
        try await coordinator.evict(recordName: Self.componentRecordName(mediaID: id, type: type))
    }

    /// Removes the local thumbnail copy + its cached change-tag so the next
    /// `loadMediaPreview` re-fetches the eager thumbnail asset from CloudKit.
    public func evictThumbnail(for id: String) {
        try? FileManager.default.removeItem(at: directoryModel.previewURLForMedia(withID: id))
        setThumbnailTag(nil, for: id)
    }
}

// MARK: - MediaBackend conformance

extension CloudKitFileAccess {

    /// `MediaBackend.reconcile`. CloudKit has no per-file scan, so `onProgress` is
    /// not applicable and is ignored — the index is brought current by the delta
    /// sync. A cancelled parent task lets the sync's own `CancellationError`
    /// propagate; `reconcile()` returns `false` in that case rather than retrying.
    @discardableResult
    public func reconcile(
        onProgress: (@Sendable (_ filesRead: Int, _ totalFiles: Int) async -> Void)? = nil
    ) async -> Bool {
        await reconcile()
    }

    /// `MediaBackend.sourceURL`. CloudKit blobs land under the `id#type` blob-cache
    /// path, not `id.ext`, so source-readers find the file after a lazy download.
    public func sourceURL(id: String, type: MediaType) async -> URL {
        cacheURL(id: id, type: type)
    }

    /// `MediaBackend.mediaIndex`. The coordinator (sharing this same store) keeps
    /// the index current; the store owns the read-through cache and reload-on-newer
    /// behavior, so this is a thin pass-through.
    public func mediaIndex() async -> MediaIndex? {
        await indexStore.current()
    }

    /// `FileReader.loadLeadingThumbnail(coverImageId:)`. Resolves the album cover
    /// through the cloud preview-fetch path (the eager thumbnail asset), rather
    /// than reading a local file that a cloud album does not have.
    public func loadLeadingThumbnail(coverImageId: String?) async throws -> UIImage? {
        guard let coverImageId, coverImageId != "none" else { return nil }
        let media = EncryptedMedia(source: .url(cacheURL(id: coverImageId, type: .photo)),
                                   mediaType: .photo,
                                   id: coverImageId)
        let interactable = try InteractableMedia(underlyingMedia: [media])
        let preview = try await loadMediaPreview(for: interactable)
        guard let data = preview.thumbnailMedia.data, let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    /// `FileWriter.setKeyUUIDForExistingFiles`. No-op for CloudKit: key-UUID xattrs
    /// are a local-disk concern. CloudKit blobs carry their key association via the
    /// record/metadata, so there is nothing to backfill.
    public func setKeyUUIDForExistingFiles() async throws {
        // Intentionally empty — see doc comment above.
    }

    /// Cross-album copy for CloudKit albums is a later chunk; fail loudly rather
    /// than silently no-op.
    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        throw CloudKitMediaStoreError.operationNotSupported("copy")
    }

    /// Cross-album move for CloudKit albums is a later chunk; fail loudly.
    public func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        throw CloudKitMediaStoreError.operationNotSupported("move")
    }
}
