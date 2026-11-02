import Foundation

/// Moves an item of a CloudKit album that is still a file in the album's
/// linked iCloud Drive folder to another album, without waiting for the album's
/// migration to reach it.
///
/// Into a CloudKit album the file is uploaded straight into the target album,
/// as a move of a local item into CloudKit uploads it (`LocalToCloudKitStep`).
/// Into a local album the ciphertext is copied into the album's directory. An
/// evicted file is downloaded first. Either way the item then leaves the source
/// album: its migration plan items, index components, sizes and folder file.
/// Its preview stays, in the global preview directory the target reads.
///
/// The album's blob migration passes are held while the item moves, so no pass
/// uploads it into the source album part-way through; a pass starts again once
/// the move ends, whatever its outcome. A crash after the copy and before the
/// source is cleaned up leaves the item in both albums.
///
/// Unlike the migration's own stores, the move's store may use cellular: it is
/// one item the user is waiting on.
@MainActor
public final class ICloudDriveItemMove: DebugPrintable {

    public enum Outcome: Equatable {
        /// The item is in the target album and gone from the source.
        case moved
        /// Every component of the item is in CloudKit already, so it moves as a
        /// CloudKit item does. Nothing was changed.
        case inCloudKit
    }

    private let albumManager: AlbumManaging
    private let makeStore: () -> CloudKitMediaStoring
    private let materializer: ICloudDriveMaterializing
    private let isICloudDriveAvailable: () -> Bool
    private let markerConflictVersions: (URL) -> [URL]
    private let startMigrationPass: @MainActor (_ albumID: String) async -> Void
    private let uploadQueue: CloudKitUploadQueue
    private let chunkStore: ChunkedBlobStoring?
    private let blobCache: CloudKitBlobCache
    private let fileSystem: ICloudDriveVerifiedDeleteFileSystem

    /// - Parameter startMigrationPass: starts a blob migration pass for the CloudKit
    ///   album `albumID` unless one is running.
    public init(albumManager: AlbumManaging,
                makeStore: @escaping () -> CloudKitMediaStoring = { CloudKitStoreProvider.makeStore("iCloudDriveItemMove") },
                materializer: ICloudDriveMaterializing? = nil,
                isICloudDriveAvailable: @escaping () -> Bool = { iCloudStorageModel.isRootAvailable },
                markerConflictVersions: @escaping (URL) -> [URL] = ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of:),
                startMigrationPass: (@MainActor (_ albumID: String) async -> Void)? = nil,
                uploadQueue: CloudKitUploadQueue = .shared,
                chunkStore: ChunkedBlobStoring? = nil,
                blobCache: CloudKitBlobCache = .shared,
                fileSystem: ICloudDriveVerifiedDeleteFileSystem = ICloudDriveVerifiedDeleteDiskFileSystem()) {
        self.albumManager = albumManager
        self.makeStore = makeStore
        self.materializer = materializer ?? ICloudDriveMaterializer()
        self.isICloudDriveAvailable = isICloudDriveAvailable
        self.markerConflictVersions = markerConflictVersions
        self.startMigrationPass = startMigrationPass ?? { albumID in
            await ICloudDriveBlobMigration.startPass(albumManager: albumManager, albumID: albumID)
        }
        self.uploadQueue = uploadQueue
        self.chunkStore = chunkStore
        self.blobCache = blobCache
        self.fileSystem = fileSystem
    }

    /// Moves `media` from the CloudKit album `source` to `target`, a CloudKit or
    /// local album.
    ///
    /// - Throws: `ICloudDriveItemWriteError.partlyInCloudKit` when only some
    ///   components are still on iCloud Drive; `ICloudDriveItemDeleteError.folderUnavailable`
    ///   when the source's linked folder cannot be verified;
    ///   `ICloudDriveItemMoveError.notMoved` when a component could not be
    ///   downloaded, uploaded or copied, or its record belongs to another album.
    ///   The item is left where it was.
    public func move(_ media: InteractableMedia<EncryptedMedia>, from source: Album, to target: Album) async throws -> Outcome {
        guard let albumID = source.albumID else { return .inCloudKit }
        await ICloudDriveBlobMigration.holdPasses(albumID: albumID)
        let result: Result<Outcome, Error>
        do {
            result = .success(try await moveHeld(media, from: source, albumID: albumID, to: target))
        } catch {
            result = .failure(error)
        }
        ICloudDriveBlobMigration.releasePasses(albumID: albumID)
        await startMigrationPass(albumID)
        return try result.get()
    }

    private func moveHeld(_ media: InteractableMedia<EncryptedMedia>,
                          from source: Album,
                          albumID: String,
                          to target: Album) async throws -> Outcome {
        let locations = await albumManager.componentLocations(of: media, in: source)
        guard locations.contains(.iCloudDrive) else { return .inCloudKit }
        guard locations.allSatisfy({ $0 == .iCloudDrive }) else {
            printDebug("move REFUSED albumID=\(albumID) mediaID=\(media.id) — only some components are still on iCloud Drive")
            throw ICloudDriveItemWriteError.partlyInCloudKit
        }
        let folder: URL
        switch ICloudDriveFolderScanner.verifiedFolder(albumID: albumID,
                                                       isICloudDriveAvailable: isICloudDriveAvailable,
                                                       linkedFolder: CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:),
                                                       markerConflictVersions: markerConflictVersions) {
        case .success(let verified): folder = verified
        case .failure(let skip):
            printDebug("move REFUSED albumID=\(albumID) mediaID=\(media.id) reason=\(skip.reason)")
            throw ICloudDriveItemDeleteError.folderUnavailable(skip.reason)
        }

        let folderAlbum = ICloudDriveAlbumMigration.linkedFolderAlbum(folder, cloudKitAlbum: source)
        let folderModel = iCloudStorageModel(album: folderAlbum)
        let urls = media.underlyingMedia.map { folderModel.driveURLForMedia(withID: $0.id, type: $0.mediaType) }
        try await materialize(urls, in: folder, mediaID: media.id)

        if target.storageOption == .cloudKit {
            try await upload(media, from: folderAlbum, model: folderModel, source: source, to: target)
        } else {
            try await copy(media, from: folderModel, to: target)
        }
        await removeFromSource(media, source: source, albumID: albumID, urls: urls)
        FileOperationBus.shared.didMove(media.underlyingMedia, to: target)
        printDebug("move ok mediaID=\(media.id) from=\(albumID) to=\(target.id)")
        return .moved
    }

    // MARK: - Steps

    private func materialize(_ urls: [URL], in folder: URL, mediaID: String) async throws {
        let evicted = urls.filter { ICloudPlaceholderName.existsInAnyForm($0) && !ICloudPlaceholderName.isMaterialized($0) }
        guard !evicted.isEmpty else { return }
        let results = await materializer.materialize(evicted, inAlbumDirectory: folder, onProgress: { _ in })
        for url in evicted {
            guard case .success = results[url] else {
                printDebug("move FAILED mediaID=\(mediaID) — \(url.lastPathComponent) did not download")
                throw ICloudDriveItemMoveError.notMoved
            }
        }
    }

    /// Uploads each component into `target` from the linked folder and verifies
    /// it there. The upload writes the target's index and sizes.
    private func upload(_ media: InteractableMedia<EncryptedMedia>,
                        from folderAlbum: Album,
                        model: iCloudStorageModel,
                        source: Album,
                        to target: Album) async throws {
        guard let targetAlbumID = target.albumID else { throw ICloudDriveItemMoveError.notMoved }
        var plan = try MigrationPlan.items(source: folderAlbum, destination: target, media: [media])
        let store = makeStore()
        let coordinator = CloudKitMigrationManager.makeIsolatedCoordinator(cloudAlbum: target, store: store,
                                                                           albumManager: albumManager, bus: .shared,
                                                                           uploadQueue: uploadQueue, chunkStore: chunkStore,
                                                                           cache: blobCache)
        let context = MigrationRunContext(source: folderAlbum,
                                          destination: target,
                                          sourceModel: model,
                                          destinationModel: nil,
                                          cloudKitAlbumID: targetAlbumID,
                                          coordinator: coordinator,
                                          store: store,
                                          uploadQueue: uploadQueue,
                                          savePlan: { _ in },
                                          storedKeys: (try? albumManager.keyManager.storedKeys()) ?? [],
                                          keyManager: albumManager.keyManager,
                                          isCancelRequested: { false },
                                          noteMissingKey: {},
                                          setPhase: { _, _, _ in },
                                          reportTransferProgress: { _, _ in })
        let step = LocalToCloudKitStep()
        for index in plan.items.indices {
            try await step.transfer(at: index, in: &plan, context: context)
            guard plan.items[index].state == .verified else {
                printDebug("move FAILED recordName=\(plan.items[index].recordName) state=\(plan.items[index].state) error=\(plan.items[index].lastError ?? "")")
                throw ICloudDriveItemMoveError.notMoved
            }
        }
    }

    /// Copies each component's ciphertext into the local album `target` and
    /// indexes it there.
    private func copy(_ media: InteractableMedia<EncryptedMedia>,
                      from folderModel: iCloudStorageModel,
                      to target: Album) async throws {
        let targetModel = target.storageOption.modelForType.init(album: target)
        try targetModel.initializeDirectories()
        var copied: [MediaType] = []
        for component in media.underlyingMedia {
            let from = folderModel.driveURLForMedia(withID: component.id, type: component.mediaType)
            let to = targetModel.driveURLForMedia(withID: component.id, type: component.mediaType)
            try CloudKitToLocalStep.placeCopy(of: from, at: to)
            guard let size = to.fileSizeBytes(), size == from.fileSizeBytes() else {
                printDebug("move FAILED mediaID=\(component.id) — the copy in \(target.id) is not the size of its file")
                try? FileManager.default.removeItem(at: to)
                throw ICloudDriveItemMoveError.notMoved
            }
            copied.append(component.mediaType)
        }
        let entry = MediaIndexEntry(id: media.id,
                                    hasPhotoComponent: copied.contains(.photo),
                                    hasVideoComponent: copied.contains(.video),
                                    dateEncrypted: nil,
                                    dateTaken: media.timestamp,
                                    subtypeRawValue: 0)
        _ = try? await albumManager.mediaIndexStore(for: target).upsert([entry])
    }

    /// Takes the item out of the source album: its plan items first, so no pass
    /// uploads it, then its index components and sizes, then its folder files.
    /// Nothing claims the record names deleted: the records are the target's.
    private func removeFromSource(_ media: InteractableMedia<EncryptedMedia>, source: Album, albumID: String, urls: [URL]) async {
        let mediaIDs: Set<String> = [media.id]
        if MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: albumID) {
            do {
                try await MigrationPlanStore(iCloudDriveMigrationFrom: source, cloudKitAlbumID: albumID).remove(mediaIDs: mediaIDs)
            } catch {
                printDebug("move planRemove FAILED albumID=\(albumID) mediaID=\(media.id) raw=\(error)")
            }
        }
        let recordNames = Set(media.underlyingMedia.map {
            MediaRecordName.componentRecordName(mediaID: $0.id, type: $0.mediaType)
        })
        let indexStore = albumManager.mediaIndexStore(for: source)
        for recordName in recordNames {
            do {
                _ = try await indexStore.removeComponent(recordName: recordName)
            } catch {
                printDebug("move indexRemove FAILED recordName=\(recordName) raw=\(error)")
            }
        }
        let entries = await indexStore.current()?.entries ?? []
        do {
            try await albumManager.sizeSidecar(for: source)
                .apply(updates: [:], removals: recordNames, owner: .iCloudDrive, entries: entries)
        } catch {
            printDebug("move sizesRemove FAILED albumID=\(albumID) raw=\(error)")
        }
        for url in urls {
            for form in fileSystem.existingForms(of: url) {
                do {
                    _ = try fileSystem.coordinatedRemove(form, expectedSize: nil)
                } catch {
                    printDebug("move WARNING \(form.lastPathComponent) could not be removed from the folder raw=\(error)")
                }
            }
        }
        albumManager.resetAlbumCover(album: source, ifItIs: media.id)
    }

}

public enum ICloudDriveItemMoveError: Error, Equatable {
    /// A component could not be downloaded, uploaded or copied, or its record
    /// belongs to another album. The item is where it was.
    case notMoved
}

public extension AlbumManaging {
    /// Whether any component of `media` is still a file in the linked iCloud
    /// Drive folder of the CloudKit album `album`, by the album's index.
    func isStillOnICloudDrive(_ media: InteractableMedia<EncryptedMedia>, in album: Album) async -> Bool {
        await componentLocations(of: media, in: album).contains(.iCloudDrive)
    }

    /// Where the album's index places each component of `media`; empty when the
    /// index has no entry for it.
    func componentLocations(of media: InteractableMedia<EncryptedMedia>, in album: Album) async -> [MediaComponentLocation] {
        guard let entry = await mediaIndexStore(for: album).current()?.entries.first(where: { $0.id == media.id }) else {
            return []
        }
        return media.underlyingMedia.compactMap { component in
            switch component.mediaType {
            case .photo: return entry.hasPhotoComponent ? entry.photoLocation : nil
            case .video: return entry.hasVideoComponent ? entry.videoLocation : nil
            default: return nil
            }
        }
    }
}
