//  Created by Alexander Freas on 12.11.23.
//

import Foundation
import Combine

// MARK: - Album Errors

public enum AlbumError: Error, CustomStringConvertible {
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
            // iCloud Drive is deprecated once CloudKit is active. A `.icloud` default may
            // still be persisted from before the flag flipped on — never hand it back, or
            // the picker-less quick-create paths would attempt a deprecated album.
            if _defaultStorageForAlbum == .icloud, FeatureToggle.isEnabled(feature: .cloudKitStorage) {
                return .local
            }
            return _defaultStorageForAlbum
        }
        set {
            _defaultStorageForAlbum = newValue
        }
    }

    public private(set) var keyManager: KeyManager

    /// The synced data store for album settings (optional, uses legacy UserDefaults if nil)
    private var albumsSyncedStore: AlbumsSyncedStore?

    private var syncedStoreCancellables = Set<AnyCancellable>()

    /// Sets the hidden state for an album
    /// Uses synced store if available, falls back to legacy UserDefaults
    public func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        if let syncedStore = albumsSyncedStore {
            do {
                try syncedStore.setAlbumHidden(album.name, isHidden: isAlbumHidden)
            } catch {
                // Fallback to legacy if encryption key unavailable
                printDebug("Failed to use synced store, falling back to UserDefaults: \(error)")
                UserDefaultUtils.set(isAlbumHidden, forKey: .isAlbumHidden(name: album.name))
            }
        } else {
            // Legacy path
            UserDefaultUtils.set(isAlbumHidden, forKey: .isAlbumHidden(name: album.name))
        }
        // Keep the `EncAlbum` record's isHidden current (last-writer-wins) so a
        // fresh device materializing the album picks up the latest state. The
        // record is otherwise frozen at create-time. No-op for non-CloudKit albums.
        pushCloudKitAlbumRecord(album)
        broadcastAlbumsUpdated()
    }

    /// Checks if an album is hidden
    /// Uses synced store if available, falls back to legacy UserDefaults
    public func isAlbumHidden(_ album: Album) -> Bool {
        if let syncedStore = albumsSyncedStore {
            do {
                return try syncedStore.isAlbumHidden(album.name)
            } catch {
                // Fallback to legacy
                printDebug("Failed to read from synced store, falling back to UserDefaults: \(error)")
                return UserDefaultUtils.bool(forKey: .isAlbumHidden(name: album.name))
            }
        }
        return UserDefaultUtils.bool(forKey: .isAlbumHidden(name: album.name))
    }

    public func fetchAlbumsFromSources(includingHidden: Bool) -> [Album] {
        let fileManager = FileManager.default
        let mapToAlbum: (URL, StorageType) -> Album? = { url, storageType in
            let directoryName = url.lastPathComponent
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let creationDate = attributes?[.creationDate] as? Date

            if let creationDate {
                return self.matchAlbumToKeyIfNeeded(albumName: directoryName, storageType: storageType, creationDate: creationDate)
            } else {
                return nil
            }
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
        // CloudKit albums keep a discovery marker under the CloudKit albums root (their
        // blobs live in CloudKit + a hashed cache). Scan unconditionally — the marker
        // only exists if a CloudKit album was created — so they appear in the grid and
        // get reconciled by the push fan-out.
        let cloudKitAlbums = CloudKitStorageModel.enumerateAlbumsDirectory()
            .compactMap { url -> Album? in
                return mapToAlbum(url, .cloudKit)
            }
        return Set(localAlbums)
            .union(Set(iCloudAlbums))
            .union(Set(cloudKitAlbums))
            .filter { includingHidden || !isAlbumHidden($0) }
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

    /// Creates a new AlbumManager
    /// - Parameters:
    ///   - keyManager: The key manager for encryption operations
    ///   - syncedDataStore: Optional synced data store for iCloud sync (uses legacy UserDefaults if nil)
    required public init(keyManager: KeyManager, syncedDataStore: SyncedDataStore? = nil) {
        self.keyManager = keyManager

        // Initialize defaultStorageForAlbum first (before any callbacks can fire)
        if let defaultStorageLocationValue = UserDefaultUtils.string(forKey: .defaultStorageLocation),
           let defaultStorageLocation = StorageType(rawValue: defaultStorageLocationValue) {
            self._defaultStorageForAlbum = defaultStorageLocation
        } else {
            self._defaultStorageForAlbum = .local
        }

        // Set up synced store if provided (after all properties are initialized)
        if let syncedDataStore = syncedDataStore {
            self.albumsSyncedStore = AlbumsSyncedStore(store: syncedDataStore)

            // Subscribe to external changes
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

        // Check if the directory exists
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, delete it
            try? fileManager.removeItem(at: albumURL)
        }

        // Remove the album's persisted metadata (including its hidden state) so
        // it doesn't linger in places that read from the synced store / legacy
        // UserDefaults — e.g. the Settings "Hidden Albums" list.
        albumsSyncedStore?.deleteAlbum(name: album.name)
        UserDefaultUtils.set(nil, forKey: .isAlbumHidden(name: album.name))
        // CloudKit albums: also remove the discovery marker + synced index, and
        // tombstone the `EncAlbum` record so the deletion propagates to other devices.
        // KNOWN GAP: the tombstone only sets `deletedAt` — the record, its `EncMedia`
        // records, and their blobs stay in the zone (`.deleteSelf` cascades only on a
        // real record delete, which never happens here). Re-creating an album with the
        // same name + key derives the same albumID, revives the record (`saveAlbum`
        // clears `deletedAt`), and a fresh index + full resync then resurrects the
        // "deleted" photos. Hard-delete/purge of the record and its media is a later
        // chunk. `.local` albums skip this entirely. (chunk 13)
        if album.storageOption == .cloudKit {
            let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
            try? fileManager.removeItem(at: marker)
            try? fileManager.removeItem(at: MediaIndexStore.indexURL(for: album))
            tombstoneCloudKitAlbumRecord(album)
        }

        albumOperationSubject.send(.albumDeleted(album: album))
        broadcastAlbumsUpdated()
        currentAlbum = fetchAlbumsFromSources().first
    }

    // MARK: - CloudKit album record sync (chunk 13)

    /// Upsert the album's `EncAlbum` record so it syncs across devices. Fire-and-forget:
    /// the on-disk marker already makes the album usable locally, and
    /// `CloudKitAlbumReconciler` self-heals a failed/offline upload on the next sync.
    /// No-op for non-CloudKit albums and when CloudKit is unavailable (the store guards
    /// on account status, so the `try?` simply discards the unavailable error).
    ///
    /// Gated on the `cloudKitStorage` feature: `EncAlbum` records only matter when the
    /// CloudKit plane is active, and the gate keeps a real `CloudKitMediaStore` (which
    /// touches the live container) from being constructed in flag-off contexts.
    private func pushCloudKitAlbumRecord(_ album: Album) {
        guard FeatureToggle.isEnabled(feature: .cloudKitStorage),
              album.storageOption == .cloudKit,
              let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) else { return }
        let upload = CloudKitAlbumUpload(albumID: hash,
                                         encName: album.encryptedPathComponent,
                                         createdAt: album.creationDate,
                                         isHidden: isAlbumHidden(album))
        let store = CloudKitStoreProvider.makeStore(hash)
        Task { try? await store.saveAlbum(upload) }
    }

    /// Tombstone the album's `EncAlbum` record (cross-device delete). The durable
    /// intent is persisted FIRST: a fire-and-forget save alone loses the delete when
    /// the device is offline, the app is killed before the task runs, or the save
    /// conflicts — and a live remote record with no local marker would then be
    /// re-materialized by the album reconciler, resurrecting the "deleted" album on
    /// this device and every other. The reconciler drains the queue and refuses to
    /// re-materialize pending albums until the tombstone is confirmed.
    ///
    /// Deliberately NOT gated on the `cloudKitStorage` feature: a `.cloudKit` album
    /// only exists from a flag-on period, and `CloudKitAlbumsSync.performSyncAll`
    /// keeps reconciling such albums with the flag off — a flag gate here would let
    /// the reconciler resurrect a flag-off delete (no tombstone queued, record still
    /// live). Both paths share the same predicate: `.cloudKit` albums always sync.
    private func tombstoneCloudKitAlbumRecord(_ album: Album) {
        guard album.storageOption == .cloudKit,
              let hash = SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes) else { return }
        let queue = CloudKitAlbumTombstoneQueue()
        queue.enqueue(hash)
        let store = CloudKitStoreProvider.makeStore(hash)
        Task {
            do {
                try await store.tombstoneAlbum(albumID: hash)
                queue.remove(hash)
            } catch {
                // Left queued — the album reconciler retries on its next pass.
            }
        }
    }

    /// `AlbumManaging.adoptCloudKitAlbum`: materialize an album the reconciler
    /// discovered in CloudKit through the manager, so observers receive the same
    /// broadcasts a locally created album produces (grid refresh, current-album
    /// consistency) instead of the marker appearing behind everyone's back.
    public func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool) {
        let album = Album(name: name, storageOption: .cloudKit, creationDate: createdAt, key: key)
        let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        try? FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        if isAlbumHidden(album) != isHidden {
            setIsAlbumHidden(isHidden, album: album)
        }
        albumOperationSubject.send(.albumCreated(album: album))
        broadcastAlbumsUpdated()
        if currentAlbum == nil {
            currentAlbum = album
        }
    }

    public func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        UserDefaultUtils.set(image.id, forKey: .albumCoverImage(albumName: album.name))
    }
    
    public func removeAlbumCover(album: Album) {
        UserDefaultUtils.set("none", forKey: .albumCoverImage(albumName: album.name))
    }
    
    public func resetAlbumCover(album: Album) {
        UserDefaultUtils.set(nil, forKey: .albumCoverImage(albumName: album.name))
    }
    
    public func getAlbumCoverImageId(album: Album) -> String? {
        return UserDefaultUtils.string(forKey: .albumCoverImage(albumName: album.name))
    }

    public func isAlbumCoverImageDisabled(album: Album) -> Bool {
        return UserDefaultUtils.string(forKey: .albumCoverImage(albumName: album.name)) == "none"
    }

    @discardableResult public func create(name: String, storageOption: StorageType) throws -> Album  {
        // iCloud Drive album creation is deprecated. Once CloudKit is active no new
        // `.icloud` albums may be created via any caller (UI pickers already hide the
        // option via DataStorageAvailabilityUtil; this is the authoritative backstop).
        if storageOption == .icloud, FeatureToggle.isEnabled(feature: .cloudKitStorage) {
            throw AlbumError.iCloudDriveDeprecated
        }
        guard let currentKey = keyManager.currentKey else {
            throw AlbumError.noCurrentKeySet
        }

        if let existingAlbum = fetchAlbumsFromSources(includingHidden: true).first(where: { $0.name == name }) {
            return existingAlbum
        }

        let album = Album(name: name, storageOption: storageOption, creationDate: Date(), key: currentKey)
        printDebug("Starting album creation process")

        let fileManager = FileManager.default
        let albumURL = album.storageURL

        printDebug("File manager and album URL are set up")

        // Check if the directory already exists
        printDebug("Checking if the directory exists at path: \(albumURL.path)")
        if fileManager.fileExists(atPath: albumURL.path) {
            // If the directory exists, throw the albumExists error
            printDebug("Directory already exists, throwing albumExists error")
            throw AlbumError.albumExists
        }

        printDebug("Directory does not exist, proceeding to create it")

        // If the directory does not exist, create it
        try fileManager.createDirectory(
            at: albumURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // CloudKit albums store blobs in CloudKit + a hashed cache (not an `Album_*`
        // dir), so also write a discovery marker so the album appears in the grid and
        // survives relaunch. Then push the `EncAlbum` record so the album syncs to the
        // user's other devices (chunk 13). `.local` albums never do either — they stay
        // pure-local and never reach CloudKit.
        if storageOption == .cloudKit {
            let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(album.encryptedPathComponent)
            try? fileManager.createDirectory(at: marker, withIntermediateDirectories: true)
            pushCloudKitAlbumRecord(album)
        }

        printDebug("Directory created successfully")
        printDebug("Broadcasting album creation")
        albumOperationSubject.send(.albumCreated(album: album))
        broadcastAlbumsUpdated()
        return album
    }

    
    public func moveAlbum(album: Album, toStorage: StorageType) throws -> Album {
        // Moving an album into iCloud Drive creates a new iCloud Drive album, which is
        // deprecated once CloudKit is active. The move picker already hides the option
        // via DataStorageAvailabilityUtil, so this is only a developer backstop: throw
        // in DEBUG to catch a forgotten call site, but stay lenient in release so a
        // missed guard isn't catastrophic for shipped builds.
        #if DEBUG
        if toStorage == .icloud, FeatureToggle.isEnabled(feature: .cloudKitStorage) {
            throw AlbumError.iCloudDriveDeprecated
        }
        #endif
        // A CloudKit move is a resumable upload, never a synchronous file move — it has
        // no correct path here, so funnel every caller through the migration engine.
        if toStorage == .cloudKit {
            throw AlbumError.migrationRequiredForCloudKit
        }
        let fileManager = FileManager.default
        let currentStorage = album.storageOption.modelForType.init(album: album)
        if toStorage == .icloud {
            try? self.keyManager.backupKeychainToiCloud(backupEnabled: true)
        }
        printDebug("Starting the move process for album: \(album.name)")

        // Determine the new storage URL based on the destination storage type
        let newStorage: DataStorageModel = toStorage == .local ? LocalStorageModel(album: album) : iCloudStorageModel(album: album)

        printDebug("Current storage URL: \(currentStorage.baseURL)")
        printDebug("New storage URL: \(newStorage.baseURL)")

        // Check if the album exists at the current location
        guard fileManager.fileExists(atPath: currentStorage.baseURL.path) else {
            printDebug("Album not found at the source location.")
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        // Ensure the destination directory exists
        if !fileManager.fileExists(atPath: newStorage.baseURL.path) {
            printDebug("Destination directory does not exist. Creating new directory.")
            try fileManager.createDirectory(at: newStorage.baseURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Move files individually to merge contents
        let enumerator = fileManager.enumerator(at: currentStorage.baseURL, includingPropertiesForKeys: nil)
        while let sourceURL = enumerator?.nextObject() as? URL {
            let destinationURL = newStorage.baseURL.appendingPathComponent(sourceURL.lastPathComponent)

            if fileManager.fileExists(atPath: destinationURL.path) {
                printDebug("File already exists at destination: \(destinationURL.path). Implementing merge logic.")
                // Implement your logic for handling duplicate files
            } else {
                printDebug("Moving file from \(sourceURL.path) to \(destinationURL.path)")
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        // Delete the source directory if it's empty
        if let contents = try? fileManager.contentsOfDirectory(atPath: currentStorage.baseURL.path), contents.isEmpty {
            printDebug("Source directory is empty after moving files. Deleting source directory.")
            try fileManager.removeItem(at: currentStorage.baseURL)
        }

        // Update the album's storage option and URL if needed
        var movedAlbum = album
        movedAlbum.storageOption = toStorage
        albumOperationSubject.send(.albumMoved(album: movedAlbum))
        broadcastAlbumsUpdated()
        printDebug("Completed the move process for album: \(album.name)")
        return movedAlbum
    }

    public func renameAlbum(album: Album, to newName: String) throws -> Album {
        // Validate the new name
        try validateAlbumName(name: newName)

        let existingAlbums = fetchAlbumsFromSources(includingHidden: true)

        // Check if an album with the new name already exists
        if existingAlbums.contains(where: { $0.name == newName }) {
            throw AlbumError.albumExists
        }
        guard var albumToUpdate = existingAlbums.first(where: { $0.id == album.id }) else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        albumToUpdate.name = newName
        // Rename the album in the file system
        let fileManager = FileManager.default
        let oldURL = album.storageURL
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(albumToUpdate.encryptedPathComponent)

        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.moveItem(at: oldURL, to: newURL)
        } else {
            throw AlbumError.albumNotFoundAtSourceLocation
        }

        albumOperationSubject.send(.albumRenamed(album: albumToUpdate))
        broadcastAlbumsUpdated()
        if currentAlbum?.id == album.id {
            currentAlbum = albumToUpdate
        }
        return albumToUpdate
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

    private func matchAlbumToKeyIfNeeded(albumName: String, storageType: StorageType, creationDate: Date) -> Album? {
        let key = keyManager.keyWith(name: albumName)
        if let key {
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        } else if let key = keyManager.currentKey {
            return Album(encryptedName: albumName, storageOption: storageType, creationDate: creationDate, key: key)
        } else {
            return nil
        }
    }
}
