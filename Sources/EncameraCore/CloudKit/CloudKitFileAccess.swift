//
//  CloudKitFileAccess.swift
//  EncameraCore
//
//  The CloudKit branch of the app's file access. Reuses the EXISTING crypto and
//  preview pipeline (`DiskFileAccess.createPreview`) unchanged — only the transport
//  differs (decision doc §6). Save encrypts with `SecretFileHandlerV2` (metadata-
//  bearing, so V2) then uploads; load lazily fetches the blob then decrypts with the
//  format-agnostic `SecretFileHandler`; enumeration comes from the coordinator's
//  synced `MediaIndexStore`; delete removes the record outright and the change
//  feed carries that to every other device.
//  `InteractableMediaFileAccess` routes here for `.cloudKit` albums behind the flag.
//
//  Reads MUST use `SecretFileHandler`, never `SecretFileHandlerV2`:
//  migration uploads the on-disk ciphertext verbatim, so a `.cloudKit` album can hold
//  V1-format blobs from a user's legacy library. `SecretFileHandlerV2` throws on V1;
//  `SecretFileHandler` sniffs the V2 magic and reads both, exactly as the local
//  `DiskFileAccess` read path does. What is stored stays byte-for-byte what was on
//  disk — the reader adapts to the data, the data is never rewritten to suit it.
//

import Foundation
import UIKit
import Combine

/// Supplies the `CloudKitMediaStoring` implementation. Production returns the real
/// store; UI tests bind a deterministic in-memory mock via `UITestSupport`.
public enum CloudKitStoreProvider {
    /// `tokenNamespace` scopes the store's zone change-token cursor per album so
    /// albums don't clobber each other's sync position. Mocks may ignore it.
    nonisolated(unsafe) public static var makeStore: @Sendable (_ tokenNamespace: String) -> CloudKitMediaStoring = { namespace in
        CloudKitMediaStore(tokenNamespace: namespace)
    }
}

public actor CloudKitFileAccess: MediaBackend, DebugPrintable {

    /// Stable per-process suite name for test-mode delete bookkeeping so every
    /// test-mode instance shares a single queue (mirroring the app-group suite
    /// that production instances share) and the suite can be cleaned up by PID.
    private static let testDeleteSuiteName = "ck-delete-test-\(ProcessInfo.processInfo.processIdentifier)"

    private let album: Album
    private let albumID: String
    /// The album's key: what saves encrypt with. Reads resolve their key per record
    /// through `keyResolver`, because a moved-in record keeps the key it was written
    /// under.
    private let keyBytes: [UInt8]
    private var keyResolver: CloudKitRecordKeyResolver
    /// The key library, for proving which key encrypted a blob before it is uploaded.
    private let keyManager: KeyManager
    private let store: CloudKitMediaStoring
    private let coordinator: CloudKitSyncCoordinator
    private let directoryModel: DataStorageModel
    private let indexStore: MediaIndexStore
    /// Reused solely for the existing preview-generation pipeline.
    private let previewAccess: DiskFileAccess
    /// Durable home for captures that have not reached CloudKit yet.
    private let uploadQueue: CloudKitUploadQueue
    private let uploader: CloudKitUploader
    /// The blob cache backing this album's coordinator — also the persistent
    /// layer for streamed chunks.
    private let blobCache: CloudKitBlobCache
    /// Transport for streamed chunks. `nil` means the CloudKit store, built
    /// per session; tests hand in an in-memory one.
    private let chunkStore: ChunkedBlobStoring?
    /// The album's CloudKit id: the store's change-token namespace, the coordinator
    /// and registry key, and the `albumID` on every record this album owns.
    static func storeNamespace(for album: Album) -> String {
        guard let albumID = album.albumID else {
            assertionFailure("a CloudKit album has no albumID")
            return ""
        }
        return albumID
    }

    public init(album: Album,
                albumManager: AlbumManaging,
                store: CloudKitMediaStoring? = nil,
                chunkStore: ChunkedBlobStoring? = nil) async {
        self.album = album
        self.chunkStore = chunkStore
        self.keyBytes = album.key.keyBytes
        self.keyManager = albumManager.keyManager
        self.keyResolver = CloudKitRecordKeyResolver(albumKey: album.key, keyManager: albumManager.keyManager)
        let albumID = Self.storeNamespace(for: album)
        self.albumID = albumID
        let resolvedStore = store ?? CloudKitStoreProvider.makeStore(albumID)
        self.store = resolvedStore
        self.directoryModel = CloudKitStorageModel(album: album)
        let index = MediaIndexStore(album: album)
        self.indexStore = index
        let sizeSidecar = AlbumSizeSidecar(album: album)
        if store != nil {
            let isolatedQueue = CloudKitUploadQueue(
                baseDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent("CloudKitUploads-test-\(UUID().uuidString)", isDirectory: true)
            )
            self.uploadQueue = isolatedQueue
            let isolatedCache = CloudKitBlobCache()
            self.blobCache = isolatedCache
            let isolatedRegistry = CloudKitCoordinatorRegistry()
            let isolatedDeletes = CloudKitMediaDeleteQueue(suiteName: Self.testDeleteSuiteName)
            self.coordinator = await isolatedRegistry.coordinator(forAlbumID: albumID) {
                CloudKitSyncCoordinator(albumID: albumID,
                                        store: resolvedStore,
                                        cache: isolatedCache,
                                        indexStore: index,
                                        sizeSidecar: sizeSidecar,
                                        uploadQueue: isolatedQueue,
                                        deleteQueue: isolatedDeletes,
                                        chunkStore: chunkStore)
            }
            self.uploader = CloudKitUploader(queue: isolatedQueue, registry: isolatedRegistry)
        } else {
            self.uploadQueue = .shared
            self.uploader = .shared
            self.blobCache = .shared
            self.coordinator = await CloudKitCoordinatorRegistry.shared.coordinator(forAlbumID: albumID) {
                CloudKitSyncCoordinator(albumID: albumID,
                                        store: resolvedStore,
                                        cache: CloudKitBlobCache.shared,
                                        indexStore: index,
                                        sizeSidecar: sizeSidecar,
                                        uploadQueue: .shared)
            }
        }
        let preview = DiskFileAccess()
        await preview.configure(for: album, albumManager: albumManager)
        self.previewAccess = preview
    }

    // MARK: - Configure

    /// `MediaBackend` conformance. A `CloudKitFileAccess` is bound to its album at
    /// `init` (it derives `albumID`, the store, and the coordinator there), so
    /// the facade constructs a fresh instance per album rather than re-pointing an
    /// existing one. This is a no-op kept only to satisfy the protocol; the warm-up
    /// is driven by `start()`, which the facade calls after construction.
    public func configure(for album: Album, albumManager: AlbumManaging) async {
    }

    // MARK: - Lifecycle

    /// Ensures the custom zone exists, registers the push subscription, and does an
    /// initial delta sync. Safe to call repeatedly; no-ops when the account is
    /// unavailable. Push-driven re-sync is handled app-wide by `CloudKitAlbumsSync`
    /// (which covers inactive albums too), not per-instance here.
    public func start() async {
        printDebug("start begin albumID=\(albumID)")
        if await store.accountAvailable() {
            do {
                try await store.ensureZoneExists()
            } catch {
                printDebug("start ensureZoneExists FAILED albumID=\(albumID) raw=\(error)")
            }
        } else {
            printDebug("start skip albumID=\(albumID) reason=accountUnavailable — zone not ensured")
        }
        await coordinator.startObserving()
        await uploader.kick()
        do {
            try await coordinator.sync(albumID: albumID)
            printDebug("start ok albumID=\(albumID)")
        } catch {
            printDebug("start initialSync FAILED albumID=\(albumID) raw=\(error)")
        }
    }

    // MARK: - Save (encrypt then upload)

    public func save(media: InteractableMedia<CleartextMedia>,
                     metadata: EncryptedFileMetadata?,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        if await store.accountAvailable() {
            do {
                try await store.ensureZoneExists()
            } catch {
                printDebug("save ensureZoneExists FAILED albumID=\(albumID) raw=\(error); continuing — the upload will surface the real error")
            }
        } else {
            printDebug("save WARNING albumID=\(albumID) account unavailable at save time; zone not ensured")
        }
        printDebug("save start albumID=\(albumID) components=\(media.underlyingMedia.count) mediaType=\(media.mediaType)")
        var encrypted: [EncryptedMedia] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let encMedia = try await saveSingle(item, metadata: metadata, progress: progress)
            encrypted.append(encMedia)
        }
        guard !encrypted.isEmpty else {
            printDebug("save FAILED albumID=\(albumID) — no components encrypted; returning nil")
            return nil
        }
        printDebug("save ok albumID=\(albumID) components=\(encrypted.count)")
        return try InteractableMedia(underlyingMedia: encrypted)
    }

    /// A unique CloudKit record name per media component. Photo and video
    /// components of a Live Photo share `mediaID` but must be distinct records.
    static func componentRecordName(mediaID: String, type: MediaType) -> String {
        MediaRecordName.componentRecordName(mediaID: mediaID, type: type)
    }

    private func saveSingle(_ item: CleartextMedia,
                            metadata: EncryptedFileMetadata?,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> EncryptedMedia {
        let encURL = directoryModel.driveURLForMedia(withID: item.id, type: item.mediaType)
        try FileManager.default.createDirectory(at: directoryModel.baseURL, withIntermediateDirectories: true)

        let plaintextLength = item.url.flatMap { $0.fileSizeBytes() } ?? 0
        var chunkGeometry: (chunkCount: Int, plaintextLength: Int64)?
        if let sourceURL = item.url,
           VideoChunkingPolicy.shouldWriteSeekableFormat(mediaType: item.mediaType,
                                                         plaintextLength: plaintextLength,
                                                         storageType: .cloudKit) {
            let metadataJSON = try SeekableEncryptedFormat.encodeMetadata(metadata ?? EncryptedFileMetadata())
            let capturedKey = keyBytes
            let header = try await Task.detached(priority: .userInitiated) {
                try SeekableEncryptedWriter(keyBytes: capturedKey)
                    .encrypt(source: sourceURL, destination: encURL, metadata: metadataJSON) { fraction in
                        progress(fraction)
                    }
            }.value
            chunkGeometry = (header.chunkCount, Int64(header.plaintextLength))
        } else {
            let handler = SecretFileHandlerV2(keyBytes: keyBytes, source: item, targetURL: encURL)
            let sub = handler.progress
                .receive(on: DispatchQueue.main)
                .sink { percent in progress(percent) }
            _ = try await handler.encryptWithMetadata(metadata ?? EncryptedFileMetadata())
            sub.cancel()
        }

        do {
            _ = try await previewAccess.createPreview(for: item)
        } catch {
            printDebug("saveSingle preview FAILED mediaID=\(item.id) mediaType=\(item.mediaType) raw=\(error)")
        }
        let previewURL = directoryModel.previewURLForMedia(withID: item.id)
        let thumbURL = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil
        if thumbURL == nil {
            printDebug("saveSingle thumbnail WARNING mediaID=\(item.id) — no preview file on disk; uploading the record without an eager thumbnail")
        }

        // Must run before the queue moves the file into the holding folder: the stamp
        // has to be part of the bytes that reach CloudKit.
        let proven = try await CloudKitKeyStamp.stampAndProveKey(forCiphertextAt: encURL,
                                                                 keyManager: keyManager)

        let size = encURL.fileSizeBytes() ?? 0
        if size == 0 {
            printDebug("saveSingle size WARNING mediaID=\(item.id) mediaType=\(item.mediaType) sizeBytes=0 file=\(encURL.lastPathComponent)")
        }
        let descriptor = CloudKitMediaRecordDescriptor(
            albumID: albumID,
            mediaID: item.id,
            recordName: Self.componentRecordName(mediaID: item.id, type: item.mediaType),
            mediaType: item.mediaType,
            createdAt: metadata?.primaryDate ?? Date(),
            sizeBytes: size,
            keyFingerprint: proven.fingerprint,
            chunkCount: chunkGeometry?.chunkCount ?? 0,
            plaintextLength: chunkGeometry?.plaintextLength ?? 0
        )
        let upload = CloudKitMediaUpload(descriptor: descriptor,
                                         encryptedFileURL: encURL,
                                         encryptedThumbURL: thumbURL)
        let queued: CloudKitMediaUpload
        do {
            queued = try await uploadQueue.enqueue(upload)
        } catch {
            printDebug("saveSingle enqueue FAILED recordName=\(upload.recordName) mediaID=\(item.id) raw=\(error)")
            throw error
        }

        try await coordinator.registerLocally(queued)

        await uploader.kick()

        printDebug("saveSingle ok mediaID=\(item.id) recordName=\(upload.recordName) state=queuedForUpload")
        return EncryptedMedia(source: .url(queued.encryptedFileURL), mediaType: item.mediaType, id: item.id)
    }

    // MARK: - Load (lazy fetch then decrypt)

    public func loadMedia(media: InteractableMedia<some MediaDescribing>,
                          progress: @escaping @Sendable (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        var decrypted: [CleartextMedia] = []
        for item in media.underlyingMedia {
            try Task.checkCancellation()
            let local = try await ensureLocalCiphertext(id: item.id, type: item.mediaType, progress: progress)
            let key = try await key(forCiphertextAt: local, id: item.id, type: item.mediaType)
            progress(.decrypting(progress: 0))
            let encMedia = EncryptedMedia(source: .url(local), mediaType: item.mediaType, id: item.id)
            let cleartext: CleartextMedia
            if item.mediaType == .photo {
                let handler = SecretFileHandler(keyBytes: key.keyBytes, source: encMedia)
                cleartext = try await handler.decryptInMemory()
            } else {
                let target = URL.tempMediaDirectory.appendingPathComponent("\(item.id).\(item.mediaType.decryptedFileExtension)")
                let handler = SecretFileHandler(keyBytes: key.keyBytes, source: encMedia, targetURL: target)
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
            let key = try await key(forCiphertextAt: local, id: item.id, type: item.mediaType)
            progress(.decrypting(progress: 0))
            let encMedia = EncryptedMedia(source: .url(local), mediaType: item.mediaType, id: item.id)
            let target = URL.tempMediaDirectory.appendingPathComponent("\(item.id).\(item.mediaType.decryptedFileExtension)")
            let handler = SecretFileHandler(keyBytes: key.keyBytes, source: encMedia, targetURL: target)
            let cleartext = try await handler.decryptToURL()
            if let url = cleartext.url { urls.append(url) }
        }
        progress(.loaded)
        return urls
    }

    /// Streaming playback for a chunked CloudKit video: stock `AVPlayerItem` over
    /// the resource loader, chunks fetched on demand through the persistent chunk
    /// cache. `nil` for anything better served by the materialize path — photos,
    /// monolithic records, and items whose bytes are still local (pending upload
    /// or a fully cached blob), where decrypt-from-disk beats the network.
    ///
    /// The first chunk is fetched here, before there is a player to wait on it.
    /// AVFoundation fails an item whose first loading request has produced no
    /// byte after ~20 s, and cold CloudKit takes longer than that to hand over a
    /// 4 MiB chunk; the caller's loading UI covers the wait instead. A first
    /// chunk that cannot be fetched throws — the video cannot be streamed.
    ///
    /// Chunk 0 is also what proves the key: the record keeps the key it was written
    /// under, so the session decrypts with the key that authenticates chunk 0, and
    /// a video no held key opens throws `missingKeyForMedia` here.
    public func streamingPlayback(for media: InteractableMedia<EncryptedMedia>) async throws -> StreamingPlayback? {
        guard media.mediaType == .video, let component = media.underlyingMedia.first(where: { $0.mediaType == .video }) else {
            return nil
        }
        let recordName = Self.componentRecordName(mediaID: component.id, type: .video)
        if await uploadQueue.pendingFileURL(recordName: recordName) != nil { return nil }
        let expectedTag = await coordinator.currentChangeTag(recordName: recordName)
        if await blobCache.cachedURL(recordName: recordName, changeTag: expectedTag) != nil { return nil }

        guard let info = try await coordinator.chunkedBlobInfo(recordName: recordName),
              let headerBytes = info.encHeader else {
            return nil
        }
        let header = try SeekableEncryptedHeader.decode(headerBytes)
        let contentTag = header.fileID.base64EncodedString()
        let chunkStore = CachedChunkedBlobStore(store: chunkStore ?? CloudKitChunkedBlobStore(),
                                                cache: blobCache,
                                                albumID: albumID,
                                                validationTag: contentTag)
        let policy = StreamingPlaybackPolicy.cloudKit
        let source = StreamingChunkSource(store: chunkStore,
                                          mediaRecordName: recordName,
                                          geometry: header.geometry,
                                          readAhead: policy.readAhead)
        guard EncryptedStreamScheme.url(mediaRecordName: recordName) != nil else { return nil }
        let prefetchStarted = Date()
        let chunk0: Data
        do {
            chunk0 = try await source.ciphertextChunk(at: 0)
            printDebug("streamingPlayback prefetch ok recordName=\(recordName) "
                       + "ms=\(Int(Date().timeIntervalSince(prefetchStarted) * 1000))")
        } catch {
            printDebug("streamingPlayback prefetch FAILED recordName=\(recordName) "
                       + "ms=\(Int(Date().timeIntervalSince(prefetchStarted) * 1000)) raw=\(error)")
            throw error
        }
        let key = try keyResolver.key(forRecordName: recordName,
                                      fingerprintHint: info.keyFingerprint,
                                      probe: FirstBlockProbe(seekableHeader: header, chunk0: Array(chunk0)))
        let session = ChunkedStreamSession.open(source: source, header: header, keyBytes: key.keyBytes)
        let loader = EncryptedStreamResourceLoader(session: session)
        printDebug("streamingPlayback ok recordName=\(recordName) chunks=\(header.chunkCount) bytes=\(header.plaintextLength)")
        return StreamingPlayback(loader: loader, session: session, policy: policy)
    }

    /// The key that opens one component's ciphertext, proven against the local copy
    /// a read just made resident — its first block, so no extra download. The
    /// record's `keyFingerprint`, when this session has seen it, is tried first.
    ///
    /// Reusable by any read of a CloudKit component that decrypts (the lightbox's
    /// metadata read, for one): make the ciphertext local, then ask here.
    func key(forCiphertextAt url: URL, id: String, type: MediaType) async throws -> PrivateKey {
        let recordName = Self.componentRecordName(mediaID: id, type: type)
        let hint = await coordinator.keyFingerprintHint(recordName: recordName)
        return try keyResolver.key(forRecordName: recordName,
                                   fingerprintHint: hint,
                                   probe: FirstBlockProbe(url: url))
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
        do {
            let url = try await coordinator.ensureBlobLocal(recordName: recordName, albumID: albumID) { fraction in
                progress(.downloading(progress: fraction))
            }
            printDebug("ensureLocalCiphertext ok recordName=\(recordName) file=\(url.lastPathComponent)")
            return url
        } catch {
            printDebug("ensureLocalCiphertext FAILED recordName=\(recordName) albumID=\(albumID) raw=\(error)")
            throw error
        }
    }

    // MARK: - Previews

    /// A thumbnail never changes once created, so any file on disk is served as
    /// is — including the one `saveSingle` wrote before the upload. CloudKit is
    /// only asked when there is no local file.
    public func loadMediaPreview(for media: InteractableMedia<some MediaDescribing>) async throws -> PreviewModel {
        let source = media.thumbnailSource!
        let previewURL = directoryModel.previewURLForMedia(withID: source.id)
        let recordName = Self.componentRecordName(mediaID: source.id, type: source.mediaType)
        if FileManager.default.fileExists(atPath: previewURL.path) {
            printDebug("loadMediaPreview thumbnail hit recordName=\(recordName) source=localFile")
        } else {
            printDebug("loadMediaPreview fetch recordName=\(recordName) reason=missingLocalFile")
            do {
                try await fetchThumbnail(recordName: recordName, to: previewURL)
                printDebug("loadMediaPreview thumbnail ok recordName=\(recordName)")
            } catch {
                printDebug("loadMediaPreview thumbnail FAILED recordName=\(recordName) raw=\(error)")
            }
        }
        var preview = try await previewAccess.loadMediaPreview(for: source)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    /// Downloads into a temporary file and moves it into place, so a concurrent
    /// reader never sees a partial file and a failed fetch leaves nothing behind.
    /// When another caller got there first, its thumbnail is kept.
    private func fetchThumbnail(recordName: String, to previewURL: URL) async throws {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString)")
            .appendingPathExtension(previewURL.pathExtension)
        defer { try? fileManager.removeItem(at: tempURL) }
        try await store.fetchThumbnail(recordName: recordName, to: tempURL)
        try fileManager.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: tempURL, to: previewURL)
        } catch where fileManager.fileExists(atPath: previewURL.path) {
            printDebug("fetchThumbnail kept existing recordName=\(recordName) — another load wrote it first")
        }
    }

    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        var preview = try await previewAccess.createPreview(for: media.thumbnailSource)
        preview.isLivePhoto = media.mediaType == .livePhoto
        return preview
    }

    // MARK: - Delete (hard delete + cross-device propagation)

    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        for interactable in media {
            for item in interactable.underlyingMedia {
                let recordName = Self.componentRecordName(mediaID: item.id, type: item.mediaType)
                printDebug("delete start recordName=\(recordName) albumID=\(albumID)")

                // Drop any durable copy still waiting to upload first, so a
                // delete cannot leave an orphan in the holding folder that the
                // uploader would later push to CloudKit — resurrecting the photo
                // the user just deleted. The entry's chunk geometry is read
                // before it goes: a partially-drained chunked upload may have
                // committed chunk records that must be reclaimed.
                let pendingGeometry = await uploadQueue.pendingItem(recordName: recordName)?.chunkCount ?? 0
                let wasPending = await uploadQueue.cancel(recordName: recordName)

                try await coordinator.remove(recordName: recordName,
                                             albumID: albumID,
                                             wasPending: wasPending,
                                             pendingChunkCount: pendingGeometry)
                let localURL = directoryModel.driveURLForMedia(withID: item.id, type: item.mediaType)
                do {
                    try FileManager.default.removeItem(at: localURL)
                    printDebug("delete ok recordName=\(recordName) localCopyRemoved=true")
                } catch {
                    let existed = FileManager.default.fileExists(atPath: localURL.path)
                    printDebug("delete ok recordName=\(recordName) localCopyRemoved=false stillPresent=\(existed) raw=\(error)")
                }
            }
        }
    }

    /// Runs the background uploader until the queue has had a full chance to
    /// empty, and waits for it. The app itself relies on `kick()`s; this is for
    /// tests and for callers that must observe upload completion.
    public func drainUploads() async {
        await uploader.drainNow()
    }

    // MARK: - Enumeration (from the synced index, never the network)

    /// Brings the local index in sync with CloudKit (delta fetch).
    @discardableResult
    public func reconcile() async -> Bool {
        do {
            try await coordinator.sync(albumID: albumID)
            printDebug("reconcile ok albumID=\(albumID)")
            return true
        } catch {
            printDebug("reconcile FAILED albumID=\(albumID) cancelled=\(error is CancellationError) raw=\(error)")
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

    /// Removes every item in the album from CloudKit and from the index.
    public func deleteAllMedia() async throws {
        let all = await enumerate()
        guard !all.isEmpty else {
            printDebug("deleteAllMedia skip albumID=\(albumID) reason=emptyAlbum")
            return
        }
        printDebug("deleteAllMedia start albumID=\(albumID) items=\(all.count)")
        try await delete(media: all)
        printDebug("deleteAllMedia ok albumID=\(albumID) items=\(all.count)")
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
        guard !underlying.isEmpty else {
            printDebug("materialize MISS mediaID=\(entry.id) — index entry has neither a photo nor a video component")
            return nil
        }
        do {
            return try InteractableMedia(underlyingMedia: underlying)
        } catch {
            printDebug("materialize FAILED mediaID=\(entry.id) components=\(underlying.count) raw=\(error)")
            return nil
        }
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

    /// Whether the component's ciphertext is in the blob cache right now. The
    /// flight check's cancel probe asserts on this: a cancelled download that
    /// secretly ran to completion caches its blob, and that shows up here no
    /// matter how fast the link is.
    public func isBlobCached(for id: String, type: MediaType) async -> Bool {
        await coordinator.isBlobCached(recordName: Self.componentRecordName(mediaID: id, type: type))
    }

    // MARK: - Storage details

    /// `MediaBackend.storageDetails`. Every component's bytes live in CloudKit;
    /// what this device holds is a cache entry that may or may not be there.
    ///
    /// The format is answered without downloading anything: a chunked record says
    /// ENC3 outright via its `chunkCount`, and an unchunked one is sniffed from the
    /// cached ciphertext when a copy is resident. A component that is neither
    /// leaves the format unknown — the blob could be ENC2 or a verbatim-migrated
    /// ENC1, and only its bytes can say which.
    public func storageDetails(for media: InteractableMedia<EncryptedMedia>) async -> MediaStorageDetails? {
        var components: [MediaStorageDetails.Component] = []
        for item in media.underlyingMedia {
            let recordName = Self.componentRecordName(mediaID: item.id, type: item.mediaType)
            let info = try? await coordinator.chunkedBlobInfo(recordName: recordName)
            let chunkCount = info?.chunkCount ?? 0
            let format: EncryptedFormatVersion?
            if chunkCount > 0 {
                format = .v3
            } else if let localURL = await coordinator.localCiphertextURL(recordName: recordName) {
                format = EncryptedFormatVersion.sniff(fileURL: localURL)
            } else {
                format = nil
            }
            components.append(
                MediaStorageDetails.Component(
                    mediaType: item.mediaType,
                    remoteBytes: await coordinator.remoteBytes(recordName: recordName),
                    localBytes: await coordinator.cachedBytes(recordName: recordName),
                    format: format,
                    chunkCount: chunkCount > 0 ? chunkCount : nil
                )
            )
        }
        return MediaStorageDetails(storageType: .cloudKit, components: components)
    }

    /// `MediaBackend.evictLocalCopy`. Drops the cached ciphertext (and every cached
    /// ENC3 chunk) for each component. The CloudKit records are untouched, so the
    /// next open re-downloads.
    public func evictLocalCopy(for media: InteractableMedia<EncryptedMedia>) async throws {
        for item in media.underlyingMedia {
            try await coordinator.evictLocalCopy(
                recordName: Self.componentRecordName(mediaID: item.id, type: item.mediaType)
            )
        }
    }

    // MARK: - Metadata

    /// `MediaBackend.loadMetadata`. Read from wherever the bytes already are, with
    /// the key proven per record:
    ///
    /// - a copy on this device (pending upload or cached blob): its header;
    /// - a chunked video: the ENC3 header the record carries, proving the key on
    ///   its sealed metadata section, so no chunk is fetched;
    /// - a photo: its blob, which the lightbox downloads to show it anyway;
    /// - a monolithic video not on this device: nothing. Its metadata sits at the
    ///   front of a blob CloudKit only serves whole, and swiping past a video must
    ///   not download it. Once it has been played the first case answers.
    public func loadMetadata(for media: InteractableMedia<EncryptedMedia>) async throws -> EncryptedFileMetadata? {
        guard let item = media.underlyingMedia.first(where: { $0.mediaType == .photo }) ?? media.underlyingMedia.first else {
            return nil
        }
        let recordName = Self.componentRecordName(mediaID: item.id, type: item.mediaType)
        if let local = await coordinator.localCiphertextURL(recordName: recordName) {
            return try await metadata(ofCiphertextAt: local, id: item.id, type: item.mediaType)
        }
        guard item.mediaType == .photo else {
            guard let info = try await coordinator.chunkedBlobInfo(recordName: recordName),
                  let headerBytes = info.encHeader else {
                printDebug("loadMetadata SKIP recordName=\(recordName) — monolithic video not on this device")
                return nil
            }
            return try metadata(ofChunkedHeader: headerBytes, recordName: recordName, fingerprintHint: info.keyFingerprint)
        }
        let local = try await ensureLocalCiphertext(id: item.id, type: item.mediaType, progress: { _ in })
        return try await metadata(ofCiphertextAt: local, id: item.id, type: item.mediaType)
    }

    private func metadata(ofCiphertextAt url: URL, id: String, type: MediaType) async throws -> EncryptedFileMetadata? {
        let key = try await key(forCiphertextAt: url, id: id, type: type)
        return try await EncryptedMetadataHandler().readMetadata(from: url, keyBytes: key.keyBytes)
    }

    private func metadata(ofChunkedHeader headerBytes: Data,
                          recordName: String,
                          fingerprintHint: String?) throws -> EncryptedFileMetadata? {
        let header = try SeekableEncryptedHeader.decode(headerBytes)
        guard let probe = FirstBlockProbe(seekableMetadataOf: header) else { return nil }
        let key = try keyResolver.key(forRecordName: recordName, fingerprintHint: fingerprintHint, probe: probe)
        guard let plain = header.openMetadata(keyBytes: key.keyBytes) else {
            throw SeekableFormatError.metadataAuthenticationFailed
        }
        return try SeekableEncryptedFormat.decodeMetadata(plain)
    }

    /// Removes the local thumbnail copy so the next
    /// `loadMediaPreview` re-fetches the eager thumbnail asset from CloudKit.
    ///
    /// Throws when the file exists but could not be removed: the flight check
    /// depends on the eviction actually happening — a swallowed failure made the
    /// next load look like a successful refetch when nothing was re-downloaded.
    /// An already-absent thumbnail is a successful eviction, not an error.
    public func evictThumbnail(for id: String) throws {
        let url = directoryModel.previewURLForMedia(withID: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            printDebug("evictThumbnail ok id=\(id) — no local thumbnail to remove")
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            printDebug("evictThumbnail ok id=\(id) file=\(url.lastPathComponent)")
        } catch {
            printDebug("evictThumbnail FAILED id=\(id) file=\(url.lastPathComponent) stillPresent=\(FileManager.default.fileExists(atPath: url.path)) raw=\(error)")
            throw error
        }
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
        guard let data = preview.thumbnailMedia.data else {
            printDebug("loadLeadingThumbnail MISS coverImageId=\(coverImageId) — preview carries no thumbnail data")
            return nil
        }
        guard let image = UIImage(data: data) else {
            printDebug("loadLeadingThumbnail MISS coverImageId=\(coverImageId) — thumbnail data is not decodable as an image, bytes=\(data.count)")
            return nil
        }
        return image
    }

    /// `FileWriter.setKeyUUIDForExistingFiles`. No-op for CloudKit: key-UUID xattrs
    /// are a local-disk concern. CloudKit blobs carry their key association via the
    /// record/metadata, so there is nothing to backfill.
    public func setKeyUUIDForExistingFiles() async throws {
    }

    /// Cross-album copy for CloudKit albums is a later chunk; fail loudly rather
    /// than silently no-op.
    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        throw CloudKitMediaStoreError.operationNotSupported("copy")
    }

    /// Cross-album move: server-side re-parent, then local index/cache/bus update.
    ///
    /// Called on the **target** album's `CloudKitFileAccess`. The store's
    /// `reassignAlbum` rewrites `albumID`, `albumRef` and `parent` on the server;
    /// the local side relocates the blob cache, upserts the target index, and
    /// emits a bus event so the gallery refreshes.
    public func move(media: InteractableMedia<EncryptedMedia>, progress: ((FileLoadingStatus) -> Void)? = nil) async throws {
        // Collect record names for all components.
        var recordNames: [String] = []
        for component in media.underlyingMedia {
            let recordName = Self.componentRecordName(mediaID: component.id, type: component.mediaType)
            // A component still in the upload queue is not reassignable yet.
            if await uploadQueue.pendingItem(recordName: recordName) != nil {
                throw CloudKitMediaStoreError.operationNotSupported("move: item \(recordName) is still uploading")
            }
            recordNames.append(recordName)
        }

        // Server-side re-parent: changes albumID, albumRef, parent.
        let notFound = try await store.reassignAlbum(recordNames: recordNames, toAlbumID: albumID)
        if !notFound.isEmpty {
            throw CloudKitMediaStoreError.notFound
        }

        // Verify every component landed under our album.
        for recordName in recordNames {
            guard try await store.confirmAlbum(recordName: recordName) == albumID else {
                throw CloudKitMediaStoreError.operationNotSupported("move: confirmation failed for \(recordName)")
            }
        }

        // Local updates: relocate cache and upsert the target index.
        for recordName in recordNames {
            await blobCache.relocate(recordName: recordName, toAlbumID: albumID)

            if let meta = try await store.fetchRecordMetadata(recordName: recordName) {
                let entry = CloudKitSyncCoordinator.indexEntry(from: meta)
                _ = try await indexStore.upsert([entry])
            }
        }

        // A sync picks up the moved records' sizes for the target album's sidecar
        // and keeps the coordinator's change tags current.
        try? await coordinator.sync(albumID: albumID)

        // Emit a bus event for the gallery to refresh.
        let busMedia = media.underlyingMedia.map { component in
            EncryptedMedia(
                source: URL(fileURLWithPath: "/cloudkit/\(albumID)/\(component.id)"),
                mediaType: component.mediaType,
                id: component.id
            )
        }
        FileOperationBus.shared.didMove(busMedia, to: album)

        progress?(.loaded)
    }
}
