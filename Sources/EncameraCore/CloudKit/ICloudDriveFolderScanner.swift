//
//  ICloudDriveFolderScanner.swift
//  EncameraCore
//
//  Keeps the `.iCloudDrive` half of a CloudKit album's media index in step with
//  the album's linked iCloud Drive folder, found through the local marker's link
//  (`CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:)`).
//
//  A scan adds an `.iCloudDrive` component for every `<mediaID>.<ext>` file the
//  index holds no component for, and removes an `.iCloudDrive` component only when
//  its file is gone in every form and the album has no record for it. Components
//  at `.cloudKit` belong to `CloudKitSyncCoordinator` and are never touched. The
//  album's size sidecar gets each `.iCloudDrive` component's size from file
//  metadata, which answers for evicted files without downloading them. A
//  watch on the folder rescans on every change and posts what changed through
//  `FileOperationBus`, so the grid refreshes without a CloudKit sync.
//

import Foundation

// MARK: - Results

/// Why a scan left the index alone.
public enum ICloudDriveFolderScanSkipReason: Equatable, Sendable {
    /// The app has no iCloud Drive container on this device.
    case iCloudDriveUnavailable
    /// The album has no link to an iCloud Drive folder.
    case noLinkedFolder
    /// The linked folder does not exist.
    case folderMissing
    /// The folder holds no marker, so nothing says it belongs to this album.
    case markerAbsent
    /// The folder's marker is only an iCloud placeholder on this device.
    case markerEvicted
    /// The folder's marker does not decode, or was written in a newer format.
    case markerUnreadable
    /// The folder's marker has conflict versions that do not all name this album.
    case markerConflicted
    /// The folder's marker names another album.
    case markerNamesAnotherAlbum(albumID: String)
    /// The index could not be saved.
    case indexWriteFailed
}

public enum ICloudDriveFolderScanResult: Equatable, Sendable {
    /// The scan ran. `added` and `removed` are the component record names
    /// (`mediaID#type`) whose `.iCloudDrive` component was added or removed.
    case scanned(added: [String], removed: [String])
    case skipped(ICloudDriveFolderScanSkipReason)
}

// MARK: - Change source

/// Reports changes inside one folder: files arriving, leaving, or finishing a
/// download. A protocol so the watch can be driven where no ubiquity container
/// exists.
@MainActor
public protocol ICloudDriveFolderChangeSource: AnyObject {
    /// Starts reporting changes in `folder`, calling `onChange` on the main queue.
    func start(watching folder: URL, onChange: @escaping @Sendable () -> Void)
    func stop()
}

/// An `NSMetadataQuery` over every item under a folder in the ubiquitous
/// documents scope. Without a ubiquity container it reports nothing.
@MainActor
public final class ICloudDriveFolderMetadataQuery: ICloudDriveFolderChangeSource {

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    public nonisolated init() {}

    public func start(watching folder: URL, onChange: @escaping @Sendable () -> Void) {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, folder.path)
        query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { _ in
                onChange()
            })
        }
        self.query = query
        query.start()
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query?.stop()
        query = nil
    }
}

// MARK: - Scanner

public actor ICloudDriveFolderScanner: DebugPrintable {

    private let album: Album
    private let indexStore: MediaIndexStore
    private let sizeSidecar: AlbumSizeSidecar
    private let sizing: ICloudDriveSizing
    private let store: CloudKitMediaStoring?
    private let bus: FileOperationBus
    private let changeSource: ICloudDriveFolderChangeSource
    private let isICloudDriveAvailable: @Sendable () -> Bool
    private let linkedFolder: @Sendable (String) -> URL?
    private let markerConflictVersions: @Sendable (URL) -> [URL]

    private var isWatching = false
    private var hasStoppedWatching = false
    private var isScanningForChange = false
    private var changeArrivedDuringScan = false

    /// - Parameters:
    ///   - album: the CloudKit album whose folder is scanned.
    ///   - indexStore: the album's index, from `AlbumManaging.mediaIndexStore(for:)`.
    ///   - sizeSidecar: the album's size sidecar, from `AlbumManaging.sizeSidecar(for:)`.
    ///   - sizing: reads the folder's file sizes from metadata, without downloading.
    ///   - store: answers whether a record exists before a component whose file is
    ///     gone is removed. Nil, or a check that fails, leaves the component in place.
    ///   - bus: where added and removed components are posted.
    ///   - changeSource: what the watch listens to.
    ///   - isICloudDriveAvailable: whether the app has an iCloud Drive container.
    ///   - linkedFolder: the folder an album id is linked to.
    ///   - markerConflictVersions: the URLs of the unresolved conflict versions of
    ///     the folder's marker.
    public init(album: Album,
                indexStore: MediaIndexStore,
                sizeSidecar: AlbumSizeSidecar,
                sizing: ICloudDriveSizing = ICloudDriveSizer(),
                store: CloudKitMediaStoring?,
                bus: FileOperationBus = .shared,
                changeSource: ICloudDriveFolderChangeSource = ICloudDriveFolderMetadataQuery(),
                isICloudDriveAvailable: @escaping @Sendable () -> Bool = { iCloudStorageModel.isRootAvailable },
                linkedFolder: @escaping @Sendable (String) -> URL? = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:),
                markerConflictVersions: @escaping @Sendable (URL) -> [URL] = ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of:)) {
        self.album = album
        self.indexStore = indexStore
        self.sizeSidecar = sizeSidecar
        self.sizing = sizing
        self.store = store
        self.bus = bus
        self.changeSource = changeSource
        self.isICloudDriveAvailable = isICloudDriveAvailable
        self.linkedFolder = linkedFolder
        self.markerConflictVersions = markerConflictVersions
    }

    // MARK: Scan

    /// Brings the index's `.iCloudDrive` components in line with the folder.
    @discardableResult
    public func scan() async -> ICloudDriveFolderScanResult {
        let folder: URL
        switch verifiedFolder() {
        case .success(let verified): folder = verified
        case .failure(let skip):
            printDebug("scan skipped albumID=\(album.albumID ?? "nil") reason=\(skip.reason)")
            return .skipped(skip.reason)
        }

        let listed = Self.listComponents(in: folder)
        let entries = await indexStore.reloadFromDisk()?.entries ?? []

        let newComponents = listed.filter { !entries.hasComponent(mediaID: $0.mediaID, type: $0.type) }
        let additions = await indexEntries(for: newComponents)

        let unlisted = Self.unlistedComponents(of: entries, listed: listed, in: folder)
        let removals = await confirmedGone(unlisted)

        let changes: IndexChanges
        do {
            changes = try await applyToIndex(additions: additions, removals: removals)
        } catch {
            printDebug("scan FAILED albumID=\(album.albumID ?? "nil") saving index error=\(error)")
            return .skipped(.indexWriteFailed)
        }

        await updateSizes(in: folder, removed: changes.removed.map(\.component.recordName))

        post(changes)

        printDebug("scan ok albumID=\(album.albumID ?? "nil") listed=\(listed.count) added=\(changes.added.count) removed=\(changes.removed.count) unlistedKept=\(unlisted.count - removals.count)")
        return .scanned(added: changes.added.map(\.recordName).sorted(),
                        removed: changes.removed.map(\.component.recordName).sorted())
    }

    /// What a scan changed in the index. `entryRemoved` is whether removing the
    /// component left its entry empty, so the entry went with it.
    private struct IndexChanges {
        var added: [FolderComponent] = []
        var removed: [(component: FolderComponent, entryRemoved: Bool)] = []
    }

    /// The index's `.iCloudDrive` components with no file in the listing.
    private static func unlistedComponents(of entries: [MediaIndexEntry],
                                           listed: [FolderComponent],
                                           in folder: URL) -> [FolderComponent] {
        let listedKeys = Set(listed.map(\.recordName))
        return iCloudDriveComponents(of: entries, in: folder).filter { !listedKeys.contains($0.recordName) }
    }

    /// The components in `unlisted` that `isConfirmedGone` says can be removed.
    private func confirmedGone(_ unlisted: [FolderComponent]) async -> [FolderComponent] {
        var gone: [FolderComponent] = []
        for component in unlisted where await isConfirmedGone(component) {
            gone.append(component)
        }
        return gone
    }

    /// Saves the additions and removals. Each is checked again against the index as
    /// saved, since it may have changed while the folder was being read.
    private func applyToIndex(additions: [(FolderComponent, MediaIndexEntry)],
                              removals: [FolderComponent]) async throws -> IndexChanges {
        try await indexStore.apply { entries in
            var changes = IndexChanges()
            for (component, entry) in additions
            where !entries.hasComponent(mediaID: component.mediaID, type: component.type) {
                entries.upsert(entry)
                changes.added.append(component)
            }
            for component in removals where entries.hasICloudDriveComponent(recordName: component.recordName) {
                changes.removed.append((component, entries.removeComponent(recordName: component.recordName)))
            }
            return changes
        }
    }

    /// Posts the changes to the bus: an added component, or a removed one whose
    /// entry survives, is a create; a removed entry is a delete.
    private func post(_ changes: IndexChanges) {
        for component in changes.added { bus.didCreate(component.media) }
        for (component, entryRemoved) in changes.removed where !entryRemoved { bus.didCreate(component.media) }
        let deleted = changes.removed.filter(\.entryRemoved).map(\.component.media)
        if !deleted.isEmpty { bus.didDelete(deleted) }
    }

    // MARK: Sizes

    /// Records the size of every `.iCloudDrive` component from file metadata and
    /// drops the sizes of `removed`. A file the metadata does not report keeps the
    /// size it has; a component the index has moved to `.cloudKit` is left to sync.
    private func updateSizes(in folder: URL, removed: [String]) async {
        let entries = await indexStore.current()?.entries ?? []
        let components = Self.iCloudDriveComponents(of: entries, in: folder)
        var updates: [String: Int64] = [:]
        if !components.isEmpty, let sizes = await sizing.logicalSizes(inAlbumDirectory: folder) {
            for component in components {
                if let bytes = sizes[component.materializedURL.lastPathComponent] {
                    updates[component.recordName] = bytes
                }
            }
        }
        guard !updates.isEmpty || !removed.isEmpty else { return }
        do {
            try await sizeSidecar.apply(updates: updates, removals: Set(removed), owner: .iCloudDrive, entries: entries)
        } catch {
            printDebug("sizes FAILED albumID=\(album.albumID ?? "nil") updated=\(updates.count) removed=\(removed.count) error=\(error)")
        }
    }

    // MARK: Watch

    /// Starts watching the linked folder; every change rescans it. Returns whether
    /// the watch is running. Never starts without iCloud Drive or a linked folder,
    /// or once `stopWatching()` has been called.
    @discardableResult
    public func startWatching() async -> Bool {
        guard !hasStoppedWatching else { return false }
        guard !isWatching else { return true }
        guard isICloudDriveAvailable(), let albumID = album.albumID, let folder = linkedFolder(albumID) else {
            printDebug("watch not started albumID=\(album.albumID ?? "nil")")
            return false
        }
        isWatching = true
        let source = changeSource
        await MainActor.run {
            source.start(watching: folder) { [weak self] in
                Task { await self?.folderDidChange() }
            }
        }
        printDebug("watch started albumID=\(albumID)")
        return true
    }

    /// Stops the watch for good: a later `startWatching()` does nothing.
    public func stopWatching() async {
        hasStoppedWatching = true
        guard isWatching else { return }
        isWatching = false
        let source = changeSource
        await MainActor.run { source.stop() }
        printDebug("watch stopped albumID=\(album.albumID ?? "nil")")
    }

    /// One scan per burst of changes: a change arriving mid-scan runs one more.
    private func folderDidChange() async {
        guard isWatching else { return }
        guard !isScanningForChange else {
            changeArrivedDuringScan = true
            return
        }
        isScanningForChange = true
        repeat {
            changeArrivedDuringScan = false
            await scan()
        } while changeArrivedDuringScan && isWatching
        isScanningForChange = false
    }

    // MARK: Folder

    struct Skip: Error { let reason: ICloudDriveFolderScanSkipReason }

    /// The linked folder, once its marker confirms it belongs to this album.
    private func verifiedFolder() -> Result<URL, Skip> {
        Self.verifiedFolder(albumID: album.albumID,
                            isICloudDriveAvailable: isICloudDriveAvailable,
                            linkedFolder: linkedFolder,
                            markerConflictVersions: markerConflictVersions)
    }

    /// The folder the album `albumID` is linked to, once the folder's marker
    /// confirms it belongs to that album. A marker that cannot be read is not
    /// taken on trust: another album's folder would otherwise be read as this
    /// album's, adding its media here and removing this album's components.
    /// Whether `folder`, a known iCloud Drive album folder, is a directory whose
    /// marker names `albumID`: the checks of `verifiedFolder(albumID:…)` past the
    /// iCloud Drive and link lookups.
    static func verifiedFolder(_ folder: URL,
                               albumID: String,
                               markerConflictVersions: (URL) -> [URL]) -> Result<URL, Skip> {
        verifiedFolder(albumID: albumID,
                       isICloudDriveAvailable: { true },
                       linkedFolder: { _ in folder },
                       markerConflictVersions: markerConflictVersions)
    }

    static func verifiedFolder(albumID: String?,
                               isICloudDriveAvailable: () -> Bool,
                               linkedFolder: (String) -> URL?,
                               markerConflictVersions: (URL) -> [URL]) -> Result<URL, Skip> {
        guard isICloudDriveAvailable() else { return .failure(Skip(reason: .iCloudDriveUnavailable)) }
        guard let albumID, let folder = linkedFolder(albumID) else {
            return .failure(Skip(reason: .noLinkedFolder))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(Skip(reason: .folderMissing))
        }
        switch ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder, conflictVersions: markerConflictVersions) {
        case .present(let marker):
            guard marker.albumID == albumID else {
                return .failure(Skip(reason: .markerNamesAnotherAlbum(albumID: marker.albumID)))
            }
            return .success(folder)
        case .conflicted(let versions):
            guard versions.allSatisfy({ $0.albumID == albumID }) else {
                return .failure(Skip(reason: .markerConflicted))
            }
            return .success(folder)
        case .absent: return .failure(Skip(reason: .markerAbsent))
        case .evicted: return .failure(Skip(reason: .markerEvicted))
        case .unreadable: return .failure(Skip(reason: .markerUnreadable))
        }
    }

    /// One media file in the folder, named by its materialized form.
    private struct FolderComponent: Hashable {
        let mediaID: String
        let type: MediaType
        /// The URL as listed: the file, or its placeholder while it is evicted.
        let listedURL: URL
        /// Where the file's bytes live once downloaded.
        let materializedURL: URL

        var recordName: String { MediaRecordName.componentRecordName(mediaID: mediaID, type: type) }

        var media: EncryptedMedia { EncryptedMedia(source: .url(materializedURL), mediaType: type, id: mediaID) }
    }

    private static let mediaTypesByExtension: [String: MediaType] = [
        MediaType.photo.encryptedFileExtension: .photo,
        MediaType.video.encryptedFileExtension: .video
    ]

    /// Every `<mediaID>.<ext>` file in `folder`, in either form. The marker and
    /// anything else are skipped.
    private static func listComponents(in folder: URL) -> [FolderComponent] {
        let urls = iCloudStorageModel.enumeratorForStorageDirectory(at: folder,
                                                                    fileExtensionFilter: Array(mediaTypesByExtension.keys))
        var seen = Set<String>()
        var components: [FolderComponent] = []
        for url in urls {
            let name = ICloudPlaceholderName.materializedFilename(from: url.lastPathComponent)
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, let type = mediaTypesByExtension[String(parts[1])] else { continue }
            let component = FolderComponent(mediaID: String(parts[0]), type: type, listedURL: url,
                                            materializedURL: folder.appendingPathComponent(name, isDirectory: false))
            if seen.insert(component.recordName).inserted { components.append(component) }
        }
        return components
    }

    /// The index's `.iCloudDrive` components, placed in `folder`.
    private static func iCloudDriveComponents(of entries: [MediaIndexEntry], in folder: URL) -> [FolderComponent] {
        var components: [FolderComponent] = []
        for entry in entries {
            for type in [MediaType.photo, .video] {
                let has = type == .photo ? entry.hasPhotoComponent : entry.hasVideoComponent
                let location = type == .photo ? entry.photoLocation : entry.videoLocation
                guard has, location == .iCloudDrive else { continue }
                let url = folder.appendingPathComponent("\(entry.id).\(type.encryptedFileExtension)", isDirectory: false)
                components.append(FolderComponent(mediaID: entry.id, type: type, listedURL: url, materializedURL: url))
            }
        }
        return components
    }

    // MARK: Entries

    /// An `.iCloudDrive` entry per new component, dated with the `createdAt` its
    /// record will get: the file's metadata is read as a migration reads it, and a
    /// Live Photo's halves share the date of the half that sorts first.
    private func indexEntries(for components: [FolderComponent]) async -> [(FolderComponent, MediaIndexEntry)] {
        guard !components.isEmpty else { return [] }
        let media = components.map { EncryptedMedia(source: .url($0.listedURL), mediaType: $0.type, id: $0.mediaID) }
        let withMetadata = await DiskFileAccess(key: album.key).encryptedMediaWithMetadata(for: media)
        var createdAtByMediaID: [String: Date] = [:]
        for item in withMetadata where createdAtByMediaID[item.media.id] == nil {
            createdAtByMediaID[item.media.id] = MigrationItem.createdAt(dateTaken: item.dateTaken,
                                                                        dateEncrypted: item.dateEncrypted,
                                                                        albumCreationDate: album.creationDate)
        }
        return components.map { component in
            let createdAt = createdAtByMediaID[component.mediaID] ?? album.creationDate
            return (component, MediaIndexEntry(id: component.mediaID,
                                               hasPhotoComponent: component.type == .photo,
                                               hasVideoComponent: component.type == .video,
                                               dateEncrypted: createdAt,
                                               dateTaken: createdAt,
                                               subtypeRawValue: 0,
                                               photoLocation: .iCloudDrive,
                                               videoLocation: .iCloudDrive))
        }
    }

    /// Whether a component missing from the listing is really gone: no file in any
    /// form, and the store confirms no record exists. A store that cannot answer
    /// counts as "a record may exist".
    private func isConfirmedGone(_ component: FolderComponent) async -> Bool {
        guard !ICloudPlaceholderName.existsInAnyForm(component.materializedURL) else { return false }
        guard let store else { return false }
        do {
            return try await store.confirmAlbum(recordName: component.recordName) == nil
        } catch {
            printDebug("record check FAILED recordName=\(component.recordName) error=\(error) — keeping the component")
            return false
        }
    }
}

private extension Array where Element == MediaIndexEntry {
    /// Whether the entry for `mediaID` has a `type` component, wherever it lives.
    func hasComponent(mediaID: String, type: MediaType) -> Bool {
        guard let entry = first(where: { $0.id == mediaID }) else { return false }
        return type == .photo ? entry.hasPhotoComponent : entry.hasVideoComponent
    }
}
