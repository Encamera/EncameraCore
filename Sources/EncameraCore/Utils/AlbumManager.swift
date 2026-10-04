//  Created by Alexander Freas on 12.11.23.
//

import Foundation
import Combine

// MARK: - Album Errors

public enum AlbumError: Error, CustomStringConvertible, Equatable {
    case albumNameError
    case albumExists
    case albumNotFoundAtSourceLocation
    case noCurrentKeySet
    /// iCloud Drive album storage is deprecated. Once the CloudKit feature flag is on,
    /// no new `.icloud` albums may be created or moved into — CloudKit is the only
    /// cloud-backed option going forward.
    case iCloudDriveDeprecated
    /// Moving an album to CloudKit is a resumable, long-running upload — it must go
    /// through `CloudKitMigrationManager`, never the synchronous `moveAlbum`.
    case migrationRequiredForCloudKit
    /// Moving a CloudKit album to another storage means downloading its blobs and
    /// cleaning up the remote records — the migration engine, never the
    /// synchronous `moveAlbum` (which would move raw record-named cache files
    /// into a layout that cannot read them, and leave a live cloud copy behind).
    case downloadRequiredFromCloudKit
    /// The CloudKit discovery marker could not be written after a migration — the
    /// album's bytes are safe in CloudKit but the album would be undiscoverable on
    /// this device, so finalize must fail (and be retried) rather than proceed.
    case cloudKitMarkerWriteFailed
    /// A storage move is running on the album. Its plan names the album, so a rename
    /// waits until the run stops.
    case moveInProgress
    /// An iCloud Drive -> This Device move finished with these files still in
    /// iCloud Drive, because they could not be downloaded or moved. Everything else
    /// moved; the iCloud Drive directory was kept, so the album shows in both places
    /// until the move is retried.
    case itemsStayedInICloudDrive(filenames: [String])
    /// The album record still has members outside the move (records on the server
    /// or captures waiting to upload), so deleting it would delete them too.
    case albumStillHasMembers

    public var description: String {
        switch self {
        case .albumNameError:
            return L10n.albumNameInvalid
        case .albumExists:
            return L10n.aKeyWithThisNameAlreadyExists
        case .albumNotFoundAtSourceLocation:
            return L10n.albumNotFoundAtSourceLocation
        case .noCurrentKeySet:
            return L10n.noKeyAvailable
        case .iCloudDriveDeprecated:
            return "iCloud Drive albums are no longer supported. Use CloudKit instead."
        case .migrationRequiredForCloudKit:
            return "Moving an album to iCloud must go through the migration flow."
        case .downloadRequiredFromCloudKit:
            return "Moving an album out of iCloud must go through the download flow."
        case .cloudKitMarkerWriteFailed:
            return "Could not finish moving the album — its files are safe in iCloud. Try again."
        case .moveInProgress:
            return L10n.albumMoveInProgressRenameError
        case .itemsStayedInICloudDrive(let filenames):
            return L10n.AlbumMove.itemsStayedInICloudDrive("\(filenames.count)")
        case .albumStillHasMembers:
            return L10n.CloudKitMigration.albumStillHasItems
        }
    }
}

public enum AlbumOperation {
    case selectedAlbumChanged(album: Album?)
    case albumsUpdated(albums: [Album])
    case albumMoved(album: Album)
    case albumDeleted(album: Album)
    case albumRenamed(album: Album)
    case albumCreated(album: Album)
}

public class AlbumManager: AlbumManaging, ObservableObject, DebugPrintable {

    public var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> {
        albumOperationSubject.eraseToAnyPublisher()
    }

    private var albumOperationSubject: PassthroughSubject<AlbumOperation, Never> = PassthroughSubject()

    @Published public var currentAlbum: Album? {
        didSet {
            albumOperationSubject.send(.selectedAlbumChanged(album: currentAlbum))
            UserDefaultUtils.set(currentAlbum?.id, forKey: .currentAlbumID)
        }
    }

    public var currentAlbumMediaCount: Int? {
        guard let currentAlbum else {
            return nil
        }
        return albumMediaCount(album: currentAlbum)
    }

    private var _defaultStorageForAlbum: StorageType {
        didSet {
            UserDefaultUtils.set(_defaultStorageForAlbum.rawValue, forKey: .defaultStorageLocation)
        }
    }

    public var defaultStorageForAlbum: StorageType {
        get {
            if _defaultStorageForAlbum == .icloud {
                return .local
            }
            return _defaultStorageForAlbum
        }
        set {
            _defaultStorageForAlbum = newValue
        }
    }

    public private(set) var keyManager: KeyManager

    /// Resolves an album's key by decrypting its name, rather than by looking a key up
    /// under a name no key has ever carried. See `matchAlbumToKeyIfNeeded`.
    private lazy var keyDiscovery = KeyDiscovery(keyManager: keyManager)

    /// Albums found on disk whose key is not on this device, as of the last scan.
    ///
    /// They are deliberately absent from `fetchAlbumsFromSources` — an album cannot be
    /// shown, counted, or written to without the key that encrypted it — but dropping
    /// them silently would tell a user their photos are gone when the album is intact
    /// and only its key is missing.
    public private(set) var lockedAlbumCount: Int = 0

    /// The locked album placeholders collected during the last scan, carrying enough
    /// metadata to render a "Missing Key" tile in the album grid.
    public private(set) var lockedAlbums: [LockedAlbumPlaceholder] = []

    /// The synced data store for album settings (optional, uses legacy UserDefaults if nil)
    private var albumsSyncedStore: AlbumsSyncedStore?

    private var syncedStoreCancellables = Set<AnyCancellable>()

    /// Sets the hidden state for an album. A CloudKit album keeps it in `album.json`
    /// and on its record; other albums use the synced store if available, falling
    /// back to legacy UserDefaults.
    public func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        if album.storageOption == .cloudKit {
            updateCloudKitAlbumMarker(album) { $0.isHidden = isAlbumHidden }
            broadcastAlbumsUpdated()
            return
        }
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setAlbumHidden(album.name, isHidden: isAlbumHidden)
                removeLegacyHiddenKey(albumName: album.name)
            } catch {
                printDebug("Failed to use synced store, falling back to UserDefaults: \(error)")
                legacyDefaults.set(isAlbumHidden, forKey: Self.legacyHiddenKey(albumName: album.name))
            }
        } else {
            legacyDefaults.set(isAlbumHidden, forKey: Self.legacyHiddenKey(albumName: album.name))
        }
        broadcastAlbumsUpdated()
    }

    /// Checks if an album is hidden. A CloudKit album reads its `album.json`; other
    /// albums use the synced store if available, falling back to legacy UserDefaults.
    public func isAlbumHidden(_ album: Album) -> Bool {
        if album.storageOption == .cloudKit {
            return cloudKitAlbumMarker(album)?.isHidden ?? false
        }
        if let syncedStore = albumsSyncedStore {
            do {
                let hidden = try syncedStore.isAlbumHidden(album.name)
                if try syncedStore.fetchAlbum(name: album.name) != nil {
                    return hidden
                }
                let legacyKey = Self.legacyHiddenKey(albumName: album.name)
                if legacyDefaults.object(forKey: legacyKey) != nil {
                    let legacyValue = legacyDefaults.bool(forKey: legacyKey)
                    try syncedStore.setAlbumHidden(album.name, isHidden: legacyValue)
                    removeLegacyHiddenKey(albumName: album.name)
                    return legacyValue
                }
                return false
            } catch {
                printDebug("Failed to read from synced store, falling back to UserDefaults: \(error)")
                return legacyDefaults.bool(forKey: Self.legacyHiddenKey(albumName: album.name))
            }
        }
        return legacyDefaults.bool(forKey: Self.legacyHiddenKey(albumName: album.name))
    }

    public func fetchAlbumsFromSources(includingHidden: Bool) -> [Album] {
        let fileManager = FileManager.default
        let storedKeys = (try? keyManager.storedKeys()) ?? []
        var lockedPlaceholders: [LockedAlbumPlaceholder] = []
        let mapToAlbum: (URL, StorageType) -> Album? = { url, storageType in
            let directoryName = url.lastPathComponent
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let creationDate = attributes?[.creationDate] as? Date

            guard let creationDate else { return nil }
            let album = self.matchAlbumToKeyIfNeeded(albumName: directoryName,
                                                     storageType: storageType,
                                                     creationDate: creationDate,
                                                     storedKeys: storedKeys)
            if album == nil {
                lockedPlaceholders.append(LockedAlbumPlaceholder(
                    encryptedDirectoryName: directoryName,
                    storageOption: storageType,
                    creationDate: creationDate,
                    requiredKey: LockedAlbumKeyProbe.requiredKey(albumDirectory: url)
                ))
            }
            return album
        }

        let localAlbums = LocalStorageModel.enumerateAlbumsDirectory()
            .compactMap { url -> Album? in
                return mapToAlbum(url, .local)
            }
        var iCloudAlbums: [Album] = []
        if DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) == .available {
            iCloudAlbums = iCloudStorageModel.enumerateAlbumsDirectory()
                .compactMap { url -> Album? in
                    return mapToAlbum(url, .icloud)
                }
        }
        var hiddenCloudKitAlbumIDs = Set<String>()
        let cloudKitAlbums = CloudKitAlbumMarker.all().compactMap { entry -> Album? in
            let album = self.cloudKitAlbum(albumID: entry.albumID, marker: entry.marker, storedKeys: storedKeys)
            if entry.marker.isHidden { hiddenCloudKitAlbumIDs.insert(entry.albumID) }
            if album == nil {
                lockedPlaceholders.append(LockedAlbumPlaceholder(
                    encryptedDirectoryName: entry.marker.encName,
                    storageOption: .cloudKit,
                    creationDate: entry.marker.createdAt,
                    requiredKey: RequiredKeyIdentity(fingerprintHex: entry.marker.keyFingerprint)
                ))
            }
            return album
        }
        lockedAlbumCount = lockedPlaceholders.count
        lockedAlbums = lockedPlaceholders
        return Set(localAlbums)
            .union(Set(iCloudAlbums))
            .union(Set(cloudKitAlbums))
            .filter { album in
                if includingHidden { return true }
                if album.storageOption == .cloudKit, let albumID = album.albumID {
                    return !hiddenCloudKitAlbumIDs.contains(albumID)
                }
                return !isAlbumHidden(album)
            }
            .sorted(by: { $0.creationDate < $1.creationDate })
    }

    public func restoreCurrentAlbumFromUserDefaults() {
        let albums = fetchAlbumsFromSources()
        if let currentAlbumID = UserDefaultUtils.string(forKey: .currentAlbumID),
           let foundAlbum = albums.first(where: { $0.id == currentAlbumID }) {
            currentAlbum = foundAlbum
        } else {
            currentAlbum = albums.first
        }
    }

    private func broadcastAlbumsUpdated() {
        albumOperationSubject.send(.albumsUpdated(albums: fetchAlbumsFromSources()))
    }

    public func notifyAlbumsChanged() {
        broadcastAlbumsUpdated()
    }

    /// - Parameters:
    ///   - keyManager: The key manager for encryption operations
    ///   - syncedDataStore: Optional synced data store for iCloud sync (uses legacy UserDefaults if nil)
    /// Builds the materializer `moveAlbum` uses to download evicted iCloud Drive
    /// files before moving them. Replaced in tests, which have no ubiquity container.
    var makeICloudDriveMaterializer: @MainActor () -> ICloudDriveMaterializing = { ICloudDriveMaterializer() }

    /// Called with each source URL just before `moveAlbum` moves it. Test seam only.
    var willMoveAlbumItem: ((URL) -> Void)?

    required public init(keyManager: KeyManager, syncedDataStore: SyncedDataStore? = nil) {
        self.keyManager = keyManager

        if let defaultStorageLocationValue = UserDefaultUtils.string(forKey: .defaultStorageLocation),
           let defaultStorageLocation = StorageType(rawValue: defaultStorageLocationValue) {
            self._defaultStorageForAlbum = defaultStorageLocation
        } else {
            self._defaultStorageForAlbum = .local
        }

        if let syncedDataStore = syncedDataStore {
            self.albumsSyncedStore = AlbumsSyncedStore(store: syncedDataStore)

            albumsSyncedStore?.externalChangePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.broadcastAlbumsUpdated()
                    self.restoreCurrentAlbumFromUserDefaults()
                }
                .store(in: &syncedStoreCancellables)
        }

        restoreCurrentAlbumFromUserDefaults()
    }

    public func delete(album: Album) {
        let fileManager = FileManager.default
        let albumURL = album.storageURL

        if fileManager.fileExists(atPath: albumURL.path) {
            try? fileManager.removeItem(at: albumURL)
        }

        wipeImportHistory(album.id)
        if album.storageOption == .cloudKit {
            removeCloudKitAlbumLocalState(album)
            deleteCloudKitAlbumRecord(album)
        } else {
            removeNameKeyedAlbumSettings(albumName: album.name)
        }

        albumOperationSubject.send(.albumDeleted(album: album))
        broadcastAlbumsUpdated()
        fixUpCurrentAlbum(deletedAlbum: album)
    }

    /// Local-only album removal for the reconciler: cleans up the filesystem,
    /// synced-store entries, and CloudKit discovery artefacts without touching the
    /// remote `EncAlbum` record or enqueueing chunk reclaim — the device that
    /// deleted the album already handled the server side.
    public func applyRemoteAlbumDeletion(album: Album) {
        let fileManager = FileManager.default
        let albumURL = album.storageURL

        if fileManager.fileExists(atPath: albumURL.path) {
            try? fileManager.removeItem(at: albumURL)
        }

        wipeImportHistory(album.id)

        if album.storageOption == .cloudKit {
            removeCloudKitAlbumLocalState(album)
        } else {
            removeNameKeyedAlbumSettings(albumName: album.name)
        }

        albumOperationSubject.send(.albumDeleted(album: album))
        broadcastAlbumsUpdated()
        fixUpCurrentAlbum(deletedAlbum: album)
    }

    /// Removes what this device holds for a CloudKit album besides its blob cache:
    /// the encrypted preview of every item in its index, `album.json`, the media
    /// index and the size and cover sidecars. All of it is keyed by the album id, so
    /// a same-named local album's settings are untouched.
    ///
    /// Previews live outside the album, keyed by media id, and the index is the only
    /// list of what the album held. Once it is gone no sync can name those items
    /// again, so they go here, before it. A move between CloudKit albums keeps the
    /// media id, so a preview another CloudKit album still indexes is left to it.
    private func removeCloudKitAlbumLocalState(_ album: Album) {
        let fileManager = FileManager.default
        let mediaIDs = Set(MediaIndexStore.storedEntries(for: album).map(\.id))
        if !mediaIDs.isEmpty {
            let stillIndexed = mediaIDsIndexedByOtherCloudKitAlbums(than: album)
            for mediaID in mediaIDs.subtracting(stillIndexed) {
                try? fileManager.removeItem(at: CloudKitStorageModel.previewURL(forMediaID: mediaID))
            }
        }
        if let albumID = album.albumID {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        try? fileManager.removeItem(at: MediaIndexStore.indexURL(for: album))
        try? fileManager.removeItem(at: AlbumSizeSidecar.sidecarURL(for: album))
        try? fileManager.removeItem(at: AlbumCoverSidecar.sidecarURL(for: album))
    }

    private func mediaIDsIndexedByOtherCloudKitAlbums(than album: Album) -> Set<String> {
        let storedKeys = (try? keyManager.storedKeys()) ?? []
        var mediaIDs = Set<String>()
        for entry in CloudKitAlbumMarker.all() where entry.albumID != album.albumID {
            guard let other = cloudKitAlbum(albumID: entry.albumID, marker: entry.marker,
                                            storedKeys: storedKeys) else { continue }
            mediaIDs.formUnion(MediaIndexStore.storedEntries(for: other).map(\.id))
        }
        return mediaIDs
    }

    /// Removes the hidden flag and cover a local or iCloud Drive album keeps under
    /// its name.
    private func removeNameKeyedAlbumSettings(albumName: String) {
        albumsSyncedStore?.deleteAlbum(name: albumName)
        removeLegacyHiddenKey(albumName: albumName)
        removeLegacyCoverImageKey(albumName: albumName)
    }

    /// After deleting the current album, fall back to the first remaining album.
    private func fixUpCurrentAlbum(deletedAlbum: Album) {
        guard currentAlbum?.id == deletedAlbum.id else { return }
        currentAlbum = fetchAlbumsFromSources().first
    }

    // MARK: - CloudKit album record sync

    private func cloudKitAlbumMarker(_ album: Album) -> CloudKitAlbumMarker? {
        album.albumID.flatMap { CloudKitAlbumMarker.read(albumID: $0) }
    }

    /// Applies `change` to a CloudKit album's `album.json`, marks it dirty and saves
    /// the album record from it. The marker stays dirty until a save succeeds, and
    /// `CloudKitAlbumReconciler` retries dirty markers on every pass. An album with no
    /// marker is not on this device, so nothing is written.
    ///
    /// - Returns: whether `album.json` was written.
    @discardableResult
    func updateCloudKitAlbumMarker(_ album: Album, _ change: (inout CloudKitAlbumMarker) -> Void) -> Bool {
        guard album.storageOption == .cloudKit,
              let albumID = album.albumID,
              var marker = CloudKitAlbumMarker.read(albumID: albumID) else {
            printDebug("updateCloudKitAlbumMarker skip album=\(album.id) reason=noMarker")
            return false
        }
        change(&marker)
        marker.dirty = true
        do {
            try marker.write(albumID: albumID)
        } catch {
            printDebug("updateCloudKitAlbumMarker write FAILED albumID=\(albumID) error=\(error)")
            return false
        }
        pushCloudKitAlbumRecord(album)
        return true
    }

    /// Upsert the album's `EncAlbum` record from its `album.json` so it syncs across
    /// devices. Fire-and-forget: the marker already makes the album usable locally.
    /// A successful save clears the marker's `dirty` flag if the marker is unchanged
    /// since; a failed one leaves it for `CloudKitAlbumReconciler` to retry. No-op for
    /// non-CloudKit albums, albums with no marker, and when CloudKit is unavailable
    /// (the store guards on account status, so the `try?` discards that error).
    ///
    /// Gated on the `cloudKitStorage` feature: `EncAlbum` records only matter when the
    /// CloudKit plane is active, and the gate keeps a real `CloudKitMediaStore` (which
    /// touches the live container) from being constructed in flag-off contexts.
    private func pushCloudKitAlbumRecord(_ album: Album) {
        guard FeatureToggle.isEnabled(feature: .cloudKitStorage),
              album.storageOption == .cloudKit,
              let albumID = album.albumID,
              let marker = CloudKitAlbumMarker.read(albumID: albumID) else { return }
        let pushed = Album(encryptedName: marker.encName, storageOption: .cloudKit,
                           creationDate: marker.createdAt, key: album.key, albumID: albumID)
        guard let albumFingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: pushed,
                                                                             keyManager: keyManager) else { return }
        let upload = CloudKitAlbumUpload(albumID: albumID,
                                         encName: marker.encName,
                                         createdAt: marker.createdAt,
                                         isHidden: marker.isHidden,
                                         keyFingerprint: albumFingerprint,
                                         coverMediaID: marker.recordCoverMediaID)
        let store = CloudKitStoreProvider.makeStore(albumID)
        Task {
            guard (try? await store.saveAlbum(upload)) != nil else { return }
            CloudKitAlbumPublishRegistry().markPublished(albumID)
            do {
                try CloudKitAlbumMarker.clearDirty(albumID: albumID, ifUnchangedFrom: marker)
            } catch {
                Self.printDebug("pushCloudKitAlbumRecord clearDirty FAILED albumID=\(albumID) error=\(error)")
            }
        }
    }

    /// Delete the album's `EncAlbum` record (cross-device delete). The durable
    /// intent is persisted FIRST: a fire-and-forget call alone loses the delete when
    /// the device is offline or the app is killed before the task runs — and a live
    /// remote record with no local marker would then be re-materialized by the album
    /// reconciler, resurrecting the "deleted" album on this device and every other.
    /// The reconciler drains the queue and refuses to re-materialize pending albums
    /// until the delete is confirmed.
    ///
    /// The record's media parent to it with `.deleteSelf`, so this reclaims their
    /// blobs too — which the old soft delete never did, because `.deleteSelf`
    /// cascades on a real delete only.
    ///
    /// Deliberately NOT gated on the `cloudKitStorage` feature: a `.cloudKit` album
    /// only exists from a flag-on period, and `CloudKitAlbumsSync.performSyncAll`
    /// keeps reconciling such albums with the flag off — a flag gate here would let
    /// the reconciler resurrect a flag-off delete (nothing queued, record still
    /// live). Both paths share the same predicate: `.cloudKit` albums always sync.
    private func deleteCloudKitAlbumRecord(_ album: Album) {
        guard album.storageOption == .cloudKit,
              let albumID = album.albumID else { return }
        let queue = CloudKitAlbumDeleteQueue()
        queue.enqueue(albumID)
        let publishRegistry = CloudKitAlbumPublishRegistry()
        let store = CloudKitStoreProvider.makeStore(albumID)
        Task {
            // Queue the chunked members' blob-zone reclaim BEFORE the album
            // record goes: the `.deleteSelf` cascade covers every `EncMedia` and
            // its assets, but chunk records live in a different zone with no
            // references, so nothing cascades to them. Once queued, any album's
            // next sync drains them (the cascaded `EncMedia` resolves as
            // already-gone and the chunks are deleted). If the membership query
            // fails, the album stays queued and the reconciler retries on its
            // next pass — the destructive erase's blob-zone wipe remains the
            // backstop.
            do {
                let members = try await store.fetchMetadata(albumID: albumID, includeThumbnail: false)
                let mediaDeleteQueue = CloudKitMediaDeleteQueue()
                for meta in members where meta.chunkCount > 0 {
                    // A move reassigns the record to another album, and the
                    // eventually-consistent query may still return it here. Confirm
                    // the record still belongs HERE before enqueueing a chunk delete
                    // that would destroy the other album's data.
                    if let currentOwner = try await store.confirmAlbum(recordName: meta.recordName),
                       currentOwner != albumID {
                        Self.printDebug("deleteCloudKitAlbumRecord skip chunk reclaim recordName=\(meta.recordName) — now owned by \(currentOwner)")
                        continue
                    }
                    mediaDeleteQueue.enqueue(meta.recordName, chunkCount: meta.chunkCount)
                }
            } catch {
                Self.printDebug("deleteCloudKitAlbumRecord chunk enumeration FAILED albumID=\(albumID) — chunked members' blob records may be orphaned until erase raw=\(error)")
                return
            }
            do {
                try await store.deleteAlbum(albumID: albumID)
                queue.remove(albumID)
                publishRegistry.forget(albumID)
            } catch {
                // Left queued — the album reconciler retries on its next pass.
            }
        }
    }

    /// `AlbumManaging.adoptCloudKitAlbum`: materialize an album the reconciler
    /// discovered in CloudKit through the manager, so observers receive the same
    /// broadcasts a locally created album produces (grid refresh, current-album
    /// consistency) instead of the marker appearing behind everyone's back.
    ///
    /// `album.json` takes the record's `encName` byte for byte, so the album this
    /// device shows is the one the record names, under the record's id.
    public func adoptCloudKitAlbum(record: CloudKitAlbumMetadata, key: PrivateKey) {
        let album = Album(encryptedName: record.encName, storageOption: .cloudKit,
                          creationDate: record.createdAt, key: key, albumID: record.albumID)
        let marker = CloudKitAlbumMarker(encName: record.encName,
                                         createdAt: record.createdAt,
                                         isHidden: record.isHidden,
                                         coverMediaID: record.coverMediaID,
                                         keyFingerprint: key.keychainLabel,
                                         dirty: false)
        do {
            try marker.write(albumID: record.albumID)
        } catch {
            printDebug("adoptCloudKitAlbum marker write FAILED albumID=\(record.albumID) error=\(error)")
        }
        albumOperationSubject.send(.albumCreated(album: album))
        broadcastAlbumsUpdated()
        if currentAlbum == nil {
            currentAlbum = album
        }
    }

    public func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        if album.storageOption == .cloudKit {
            updateCloudKitAlbumMarker(album) { $0.coverMediaID = image.id }
            return
        }
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(album.name, coverImageId: image.id)
                removeLegacyCoverImageKey(albumName: album.name)
                return
            } catch {
                printDebug("Failed to set cover image in synced store: \(error)")
            }
        }
        legacyDefaults.set(image.id, forKey: Self.legacyCoverImageKey(albumName: album.name))
    }

    public func removeAlbumCover(album: Album) {
        if album.storageOption == .cloudKit {
            updateCloudKitAlbumMarker(album) { $0.coverMediaID = CloudKitAlbumMarker.disabledCoverID }
            return
        }
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(album.name, coverImageId: "none")
                removeLegacyCoverImageKey(albumName: album.name)
                return
            } catch {
                printDebug("Failed to remove cover image in synced store: \(error)")
            }
        }
        legacyDefaults.set("none", forKey: Self.legacyCoverImageKey(albumName: album.name))
    }

    public func resetAlbumCover(album: Album) {
        if album.storageOption == .cloudKit {
            updateCloudKitAlbumMarker(album) { $0.coverMediaID = nil }
            // The synced cover cached from the record would otherwise stand in for it.
            try? FileManager.default.removeItem(at: AlbumCoverSidecar.sidecarURL(for: album))
            return
        }
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(album.name, coverImageId: nil)
                removeLegacyCoverImageKey(albumName: album.name)
                return
            } catch {
                printDebug("Failed to reset cover image in synced store: \(error)")
            }
        }
        legacyDefaults.removeObject(forKey: Self.legacyCoverImageKey(albumName: album.name))
    }

    /// The album's chosen cover: a media id, `"none"` when the cover is turned off,
    /// or nil when the album picks its own. A CloudKit album reads its `album.json`.
    public func getAlbumCoverImageId(album: Album) -> String? {
        if album.storageOption == .cloudKit {
            return cloudKitAlbumMarker(album)?.coverMediaID
        }
        if let syncedStore = albumsSyncedStore {
            do {
                if let id = try syncedStore.getCoverImageId(album.name) {
                    return id
                }
                let legacyKey = Self.legacyCoverImageKey(albumName: album.name)
                if let legacyValue = legacyDefaults.string(forKey: legacyKey) {
                    try syncedStore.setCoverImageId(album.name, coverImageId: legacyValue)
                    removeLegacyCoverImageKey(albumName: album.name)
                    return legacyValue
                }
                return nil
            } catch {
                printDebug("Failed to read cover image from synced store: \(error)")
            }
        }
        return legacyDefaults.string(forKey: Self.legacyCoverImageKey(albumName: album.name))
    }

    /// Writes a local album's cover (a media id, or `"none"`) under its name.
    private func setNameKeyedCoverImageId(_ coverImageId: String, albumName: String) {
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setCoverImageId(albumName, coverImageId: coverImageId)
                removeLegacyCoverImageKey(albumName: albumName)
                return
            } catch {
                printDebug("Failed to set cover image in synced store: \(error)")
            }
        }
        legacyDefaults.set(coverImageId, forKey: Self.legacyCoverImageKey(albumName: albumName))
    }

    public func isAlbumCoverImageDisabled(album: Album) -> Bool {
        return getAlbumCoverImageId(album: album) == "none"
    }

    // MARK: - Legacy key helpers

    private static func legacyCoverImageKey(albumName: String) -> String {
        "albumCoverImage(albumName: \"\(albumName)\")"
    }

    private static func legacyHiddenKey(albumName: String) -> String {
        "isAlbumHidden(name: \"\(albumName)\")"
    }

    private var legacyDefaults: UserDefaults {
        UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
    }

    private func removeLegacyCoverImageKey(albumName: String) {
        let key = Self.legacyCoverImageKey(albumName: albumName)
        legacyDefaults.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    private func removeLegacyHiddenKey(albumName: String) {
        let key = Self.legacyHiddenKey(albumName: albumName)
        legacyDefaults.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    @discardableResult public func create(name: String, storageOption: StorageType) throws -> Album  {
        if storageOption == .icloud {
            throw AlbumError.iCloudDriveDeprecated
        }
        guard let currentKey = keyManager.currentKey else {
            throw AlbumError.noCurrentKeySet
        }

        if let existingAlbum = fetchAlbumsFromSources(includingHidden: true).first(where: { $0.name == name }) {
            return existingAlbum
        }

        let album = Album(name: name,
                          storageOption: storageOption,
                          creationDate: Date(),
                          key: currentKey,
                          albumID: storageOption == .cloudKit ? UUID().uuidString : nil)
        printDebug("Starting album creation process")

        let fileManager = FileManager.default
        let albumURL = album.storageURL

        printDebug("File manager and album URL are set up")

        printDebug("Checking if the directory exists at path: \(albumURL.path)")
        if fileManager.fileExists(atPath: albumURL.path) {
            printDebug("Directory already exists, throwing albumExists error")
            throw AlbumError.albumExists
        }

        printDebug("Directory does not exist, proceeding to create it")

        try fileManager.createDirectory(
            at: albumURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if storageOption == .cloudKit, let albumID = album.albumID {
            try CloudKitAlbumMarker(album: album, isHidden: false, dirty: true).write(albumID: albumID)
            pushCloudKitAlbumRecord(album)
        }

        printDebug("Directory created successfully")
        printDebug("Broadcasting album creation")
        albumOperationSubject.send(.albumCreated(album: album))
        broadcastAlbumsUpdated()
        return album
    }

    
    /// Moves an iCloud Drive (or local) album's files into local storage.
    ///
    /// Runs off the main actor. Every file is downloaded through the iCloud Drive
    /// materializer before it moves, so an evicted file's `.icloud` placeholder is
    /// never what lands in local storage. A file that cannot be downloaded or moved
    /// stays where it is; the source directory is removed only once every file has
    /// moved, and otherwise the call throws `AlbumError.itemsStayedInICloudDrive`
    /// naming what stayed, leaving the album readable in both places.
    ///
    /// When the destination already holds a file of the same name, identical bytes
    /// drop the source copy (the destination is a confirmed copy) and different
    /// bytes keep both, the moved one under a new name.
    public func moveAlbum(album: Album,
                          toStorage: StorageType,
                          onProgress: @escaping @Sendable (AlbumMoveProgress) -> Void) async throws -> Album {
        if toStorage == .icloud {
            throw AlbumError.iCloudDriveDeprecated
        }
        if toStorage == .cloudKit {
            throw AlbumError.migrationRequiredForCloudKit
        }
        if album.storageOption == .cloudKit {
            throw AlbumError.downloadRequiredFromCloudKit
        }
        let fileManager = FileManager.default
        let sourceDirectory = album.storageOption.modelForType.init(album: album).baseURL
        printDebug("Starting the move process for album: \(album.name)")
        printDebug("Current storage URL: \(sourceDirectory)")

        guard fileManager.fileExists(atPath: sourceDirectory.path) else {
            printDebug("Album not found at the source location.")
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        let destinationDirectory = LocalStorageModel(album: album).baseURL
        printDebug("New storage URL: \(destinationDirectory)")

        if !fileManager.fileExists(atPath: destinationDirectory.path) {
            printDebug("Destination directory does not exist. Creating new directory.")
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        let entries = try fileManager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        var files: [URL] = []
        var stayed: [String] = []
        var seen = Set<String>()
        for entry in entries {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                printDebug("Leaving directory \(entry.lastPathComponent) in place; only files are moved")
                stayed.append(entry.lastPathComponent)
                continue
            }
            // A `.<name>.icloud` placeholder stands for `<name>`; the file moved is
            // always the materialized one, never the placeholder.
            let name = ICloudPlaceholderName.materializedFilename(from: entry.lastPathComponent)
            guard seen.insert(name).inserted else { continue }
            files.append(sourceDirectory.appendingPathComponent(name))
        }

        let total = files.count
        var completed = 0
        onProgress(AlbumMoveProgress(completed: 0, total: total))

        let materializer = await makeICloudDriveMaterializer()
        let batchSize = max(ICloudDriveMigrationBatchSize.current, 1)
        for batchStart in stride(from: 0, to: files.count, by: batchSize) {
            let batch = Array(files[batchStart..<min(batchStart + batchSize, files.count)])
            let results = await materializer.materialize(batch, inAlbumDirectory: sourceDirectory, onProgress: { _ in })
            for url in batch {
                defer {
                    completed += 1
                    onProgress(AlbumMoveProgress(completed: completed, total: total))
                }
                switch results[url] {
                case .success(let downloaded)?:
                    guard ICloudPlaceholderName.isMaterialized(downloaded) else {
                        printDebug("\(url.lastPathComponent) is still a placeholder after download; leaving it in iCloud Drive")
                        stayed.append(url.lastPathComponent)
                        continue
                    }
                    do {
                        try moveDownloadedAlbumItem(downloaded, into: destinationDirectory)
                    } catch {
                        printDebug("Could not move \(url.lastPathComponent): \(error); leaving it in iCloud Drive")
                        stayed.append(url.lastPathComponent)
                    }
                case .failure(let error)?:
                    printDebug("Could not download \(url.lastPathComponent): \(error); leaving it in iCloud Drive")
                    stayed.append(url.lastPathComponent)
                case nil:
                    printDebug("No download result for \(url.lastPathComponent); leaving it in iCloud Drive")
                    stayed.append(url.lastPathComponent)
                }
            }
        }

        if stayed.isEmpty {
            let leftovers = (try? fileManager.contentsOfDirectory(atPath: sourceDirectory.path)) ?? []
            if leftovers.isEmpty {
                printDebug("Source directory is empty after moving files. Deleting source directory.")
                try fileManager.removeItem(at: sourceDirectory)
            } else {
                printDebug("Source directory still holds \(leftovers.count) item(s); keeping it")
                stayed = leftovers
            }
        }

        guard stayed.isEmpty else {
            printDebug("Move of album \(album.name) left \(stayed.count) item(s) in place: \(stayed)")
            broadcastAlbumsUpdated()
            throw AlbumError.itemsStayedInICloudDrive(filenames: stayed.sorted())
        }

        var movedAlbum = album
        movedAlbum.storageOption = toStorage
        wipeImportHistory(album.id, movedAlbum.id)
        albumOperationSubject.send(.albumMoved(album: movedAlbum))
        broadcastAlbumsUpdated()
        printDebug("Completed the move process for album: \(album.name)")
        return movedAlbum
    }

    /// Moves one downloaded file into `destinationDirectory`, resolving a name
    /// collision: identical bytes drop the source copy, different bytes keep both.
    private func moveDownloadedAlbumItem(_ sourceURL: URL, into destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        willMoveAlbumItem?(sourceURL)

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return
        }
        if fileManager.contentsEqual(atPath: sourceURL.path, andPath: destinationURL.path) {
            printDebug("\(sourceURL.lastPathComponent) already exists at the destination with identical contents; removing the source copy")
            try fileManager.removeItem(at: sourceURL)
            return
        }
        let keptURL = Self.uniqueDestinationURL(for: sourceURL.lastPathComponent, in: destinationDirectory)
        printDebug("\(sourceURL.lastPathComponent) differs from the file already at the destination; keeping both, moved copy saved as \(keptURL.lastPathComponent)")
        try fileManager.moveItem(at: sourceURL, to: keptURL)
    }

    /// `<id>-<n>.<extensions>` for the first `n` not already taken in `directory`.
    static func uniqueDestinationURL(for filename: String, in directory: URL) -> URL {
        let stem = filename.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? filename
        let suffix = filename.dropFirst(stem.count)
        var index = 1
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index)\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// Completes a resumable local/iCloud -> CloudKit migration by flipping the
    /// album's storage *identity* (the bytes are already in CloudKit + its on-device
    /// cache; the migration engine uploaded and deleted every file). Writes
    /// `albums/<albumID>/album.json` so the album is found as a CloudKit album, drops
    /// the drained source directory so it isn't also discovered as an empty
    /// source-storage album, and broadcasts the change so the grid refreshes.
    ///
    /// The source's hidden flag and cover move into `album.json`, and its name-keyed
    /// settings are removed once its directory is gone. A move into a CloudKit album
    /// this device already holds keeps that album's `album.json` as it is.
    @discardableResult
    public func finalizeMigrationToCloudKit(album: Album, albumID: String) throws -> Album {
        let cloudKitAlbum: Album
        if let existing = CloudKitAlbumMarker.read(albumID: albumID) {
            cloudKitAlbum = Album(encryptedName: existing.encName, storageOption: .cloudKit,
                                  creationDate: existing.createdAt, key: album.key, albumID: albumID)
        } else {
            cloudKitAlbum = Album.cloudKitTwin(of: album, albumID: albumID)
            try CloudKitAlbumMarker(album: cloudKitAlbum,
                                    isHidden: isAlbumHidden(album),
                                    coverMediaID: getAlbumCoverImageId(album: album),
                                    dirty: true).write(albumID: albumID)
        }
        guard CloudKitAlbumMarker.exists(albumID: albumID) else {
            throw AlbumError.cloudKitMarkerWriteFailed
        }
        pushCloudKitAlbumRecord(cloudKitAlbum)

        if album.storageOption != .cloudKit {
            let sourceModel = album.storageOption.modelForType.init(album: album)
            if Album.removeDrainedSourceDirectory(at: sourceModel.baseURL) {
                removeNameKeyedAlbumSettings(albumName: album.name)
            }
        }

        wipeImportHistory(album.id, cloudKitAlbum.id)
        if currentAlbum?.id == album.id { currentAlbum = cloudKitAlbum }
        albumOperationSubject.send(.albumMoved(album: cloudKitAlbum))
        broadcastAlbumsUpdated()
        return cloudKitAlbum
    }

    /// Completes a whole CloudKit album's move back to local storage. The engine has
    /// already copied and verified every item into the local layout and removed
    /// every media record; this drops what is left of the album in CloudKit and on
    /// this device: the album record, `album.json`, the blob cache, both indexes and
    /// the sidecars. The album id goes with them; a later move back to CloudKit
    /// resolves a new one. `album.json` going is what makes the local album
    /// discoverable, so a failure to remove it throws and the engine keeps its
    /// checkpoint to retry.
    ///
    /// The hidden flag and cover in `album.json` move to the local album's name-keyed
    /// settings.
    ///
    /// The album record is deleted only after `CloudKitAlbumMembership` finds nothing
    /// but `movedRecordNames` pointing at it: every media record parents to it with
    /// `.deleteSelf`, so the delete would take any other member with it. Otherwise,
    /// or when the check cannot run, it throws before touching anything, leaving
    /// the record, `album.json`, the blob cache and the indexes as they are.
    @discardableResult
    public func finalizeMigrationToLocal(album: Album, movedRecordNames: Set<String>) async throws -> Album {
        let localAlbum = Album.localTwin(of: album)
        let marker = cloudKitAlbumMarker(album)
        if let albumID = album.albumID {
            let store = CloudKitStoreProvider.makeStore(albumID)
            let remaining = try await CloudKitAlbumMembership.members(ofAlbumID: albumID, store: store)
                .excluding(movedRecordNames)
            guard remaining.isEmpty else {
                printDebug("finalizeMigrationToLocal REFUSED album=\(album.name) — records=\(remaining.records.count) queued=\(remaining.queuedUploads.count) still point at the album record")
                throw AlbumError.albumStillHasMembers
            }
            let queue = CloudKitAlbumDeleteQueue()
            queue.enqueue(albumID)
            do {
                try await store.deleteAlbum(albumID: albumID)
                queue.remove(albumID)
                CloudKitAlbumPublishRegistry().forget(albumID)
            } catch {
                printDebug("finalizeMigrationToLocal album delete FAILED album=\(album.name) — left queued for retry raw=\(error)")
            }
            try CloudKitAlbumMarker.remove(albumID: albumID)
        }
        try? FileManager.default.removeItem(at: CloudKitStorageModel(album: album).baseURL)
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: localAlbum))
        try? FileManager.default.removeItem(at: AlbumSizeSidecar.sidecarURL(for: album))
        try? FileManager.default.removeItem(at: AlbumCoverSidecar.sidecarURL(for: album))

        if let marker {
            removeNameKeyedAlbumSettings(albumName: localAlbum.name)
            if marker.isHidden {
                setIsAlbumHidden(true, album: localAlbum)
            }
            if let coverMediaID = marker.coverMediaID {
                setNameKeyedCoverImageId(coverMediaID, albumName: localAlbum.name)
            }
        }
        wipeImportHistory(album.id, localAlbum.id)

        if currentAlbum?.id == album.id { currentAlbum = localAlbum }
        albumOperationSubject.send(.albumMoved(album: localAlbum))
        broadcastAlbumsUpdated()
        printDebug("finalizeMigrationToLocal completed album=\(album.name)")
        return localAlbum
    }

    /// Renames an album in place. A local album's directory moves to the new name's
    /// ciphertext, carrying its name-keyed hidden flag and cover, and its unfinished
    /// storage moves: a local album's id is its name, so every plan naming it moves
    /// with it (`MigrationPlanStore.carryPlans`). A CloudKit album keeps its id and
    /// everything keyed by it: only `encName` in `album.json` changes, and the record
    /// is saved from it in the background (see `updateCloudKitAlbumMarker`).
    ///
    /// Throws `.albumExists` when any other album on this device, hidden or not and in
    /// any storage, already has the name, and `.moveInProgress` while a storage move
    /// is running on the album.
    public func renameAlbum(album: Album, to newName: String) throws -> Album {
        try validateAlbumName(name: newName)
        if newName == album.name {
            return album
        }
        if CloudKitMigrationManager.isActive(albumID: album.id) {
            throw AlbumError.moveInProgress
        }
        if albumNamed(newName, otherThan: album) != nil {
            throw AlbumError.albumExists
        }
        guard var albumToUpdate = fetchAlbumsFromSources(includingHidden: true).first(where: { $0.id == album.id }) else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        if album.storageOption == .cloudKit {
            albumToUpdate.name = newName
            let encName = albumToUpdate.encryptedPathComponent
            guard updateCloudKitAlbumMarker(albumToUpdate, { $0.encName = encName }) else {
                throw AlbumError.albumNotFoundAtSourceLocation
            }
            if currentAlbum?.id == album.id {
                currentAlbum = albumToUpdate
            }
            albumOperationSubject.send(.albumRenamed(album: albumToUpdate))
            broadcastAlbumsUpdated()
            return albumToUpdate
        }

        // The synced store keys the hidden flag and cover by name, so both are read
        // before the rename and written under the new name after it.
        let wasHidden = isAlbumHidden(album)
        let coverId = getAlbumCoverImageId(album: album)

        let renamedFrom = albumToUpdate
        albumToUpdate.name = newName
        let fileManager = FileManager.default
        let oldURL = album.storageURL
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(albumToUpdate.encryptedPathComponent)

        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.moveItem(at: oldURL, to: newURL)
        } else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        if wasHidden {
            setIsAlbumHidden(true, album: albumToUpdate)
        }
        if let coverId {
            if let syncedStore = albumsSyncedStore {
                try? syncedStore.setCoverImageId(albumToUpdate.name, coverImageId: coverId)
            } else {
                legacyDefaults.set(coverId, forKey: Self.legacyCoverImageKey(albumName: albumToUpdate.name))
            }
        }
        albumsSyncedStore?.deleteAlbum(name: album.name)
        removeLegacyHiddenKey(albumName: album.name)
        removeLegacyCoverImageKey(albumName: album.name)

        do {
            let carried = try MigrationPlanStore.carryPlans(acrossRenameOf: renamedFrom, to: albumToUpdate,
                                                            otherAlbums: fetchAlbumsFromSources(includingHidden: true))
            // A move of the whole album can already have an `album.json` for its
            // destination, adopted from the server mid-move. Finalize keeps that
            // marker, so it takes the new name now.
            for plan in carried where plan.scope == .album {
                guard let twinID = plan.destination.cloudKitAlbumID else { continue }
                let twin = Album.cloudKitTwin(of: albumToUpdate, albumID: twinID)
                let encName = twin.encryptedPathComponent
                _ = updateCloudKitAlbumMarker(twin) { $0.encName = encName }
            }
        } catch {
            printDebug("renameAlbum could not carry the album's pending moves: \(error)")
        }

        // A local album's id is its name, so its history file moves with the rename.
        do {
            try AlbumImportHistory.moveFile(fromAlbumId: album.id, toAlbumId: albumToUpdate.id)
        } catch {
            printDebug("Could not carry import history over to renamed album \(newName): \(error)")
        }

        albumOperationSubject.send(.albumRenamed(album: albumToUpdate))
        broadcastAlbumsUpdated()
        if currentAlbum?.id == album.id {
            currentAlbum = albumToUpdate
        }
        return albumToUpdate
    }

    /// Removes the import history kept under each album id. Moving an album starts
    /// its history over: nothing is carried across storage types.
    private func wipeImportHistory(_ albumIds: String...) {
        for albumId in albumIds {
            do {
                try AlbumImportHistory.deleteFile(forAlbumId: albumId)
            } catch {
                printDebug("Could not remove import history for album id \(albumId): \(error)")
            }
        }
    }

    public func storageModel(for album: Album) -> DataStorageModel? {
        album.storageOption.modelForType.init(album: album)
    }

    public func validateAlbumName(name: String) throws {
        guard name.count > 0 else {
            throw KeyManagerError.keyNameError
        }
    }

    public func albumMediaCount(album: Album) -> Int {
        // CloudKit albums keep membership in the synced index, not as on-disk files —
        // a directory scan would report 0 on a metadata-only device.
        if album.storageOption == .cloudKit {
            return MediaIndexStore.entryCount(for: album)
        }
        let storageModel = storageModel(for: album)
        return storageModel?.countOfFiles(matchingFileExtension: [MediaType.photo.encryptedFileExtension, MediaType.video.encryptedFileExtension]) ?? 0
    }

    /// Builds the CloudKit album a marker describes, with the key that encrypted its
    /// name. Nil when no held key opens the name: a CloudKit album never falls back
    /// to the current key, since the name ciphertext always came from a real key.
    private func cloudKitAlbum(albumID: String,
                               marker: CloudKitAlbumMarker,
                               storedKeys: [PrivateKey]) -> Album? {
        switch keyDiscovery.key(forEncryptedAlbumName: marker.encName,
                                hint: marker.keyFingerprint,
                                storedKeysSnapshot: storedKeys) {
        case .resolved(let key):
            return Album(encryptedName: marker.encName,
                         storageOption: .cloudKit,
                         creationDate: marker.createdAt,
                         key: key,
                         albumID: albumID)
        case .notProvable, .noKnownKey:
            return nil
        }
    }

    /// Builds the album a directory represents, keyed by the key that actually
    /// encrypted it.
    ///
    /// The directory name IS the album's name encrypted with the album's own key, so
    /// the key is recoverable from it by trying candidates and keeping the one that
    /// authenticates. Names cannot identify a key here: every key is named
    /// `encamera_default_key`.
    ///
    /// A locked album returns nil rather than taking the current key. `Album.key` feeds
    /// the album's name, its identity, its media index and its CloudKit hash, so
    /// attaching a key that cannot read it does not degrade gracefully — it produces an
    /// album that is a different album, and writes new media under a key the rest of
    /// its contents do not share.
    private func matchAlbumToKeyIfNeeded(albumName: String,
                                         storageType: StorageType,
                                         creationDate: Date,
                                         storedKeys: [PrivateKey]) -> Album? {
        switch keyDiscovery.key(forEncryptedAlbumName: albumName, storedKeysSnapshot: storedKeys) {
        case .resolved(let key):
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        case .notProvable:
            // A legacy plaintext directory name, which no key encrypted. The current
            // key is as good an answer as exists, and is what shipped.
            guard let key = keyManager.currentKey else { return nil }
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        case .noKnownKey:
            return nil
        }
    }
}
