//
//  AlbumManaging.swift
//
//
//  Created by Alexander Freas on 19.11.23.
//

import Foundation
import Combine
import UIKit

public protocol AlbumManaging {

    init(keyManager: KeyManager, syncedDataStore: SyncedDataStore?)
    var keyManager: KeyManager { get }
    var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> { get }
    var defaultStorageForAlbum: StorageType { get set }
    var currentAlbum: Album? { get set }
    var currentAlbumMediaCount: Int? { get }
    /// Throws `AlbumError.moveInProgress` for an album a storage move names.
    func delete(album: Album) throws
    /// Removes the album locally without touching CloudKit records — the device
    /// that deleted the album already handled the server side. Used by
    /// the reconciler when the change feed reports a deletion.
    func applyRemoteAlbumDeletion(album: Album)
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>)
    func removeAlbumCover(album: Album)
    func resetAlbumCover(album: Album)
    func getAlbumCoverImageId(album: Album) -> String?
    func isAlbumCoverImageDisabled(album: Album) -> Bool
    func fetchAlbumsFromSources(includingHidden: Bool) -> [Album]
    func restoreCurrentAlbumFromUserDefaults()
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album
    func storageModel(for album: Album) -> DataStorageModel?
    /// Moves a local or iCloud Drive album to local storage, downloading evicted
    /// files first. Throws `AlbumError.itemsStayedInICloudDrive` when some files
    /// could not be moved; the album then stays in both places. See `AlbumManager`.
    func moveAlbum(album: Album,
                   toStorage: StorageType,
                   onProgress: @escaping @Sendable (AlbumMoveProgress) -> Void) async throws -> Album
    /// Flips a drained local or iCloud Drive album to the CloudKit album `albumID`:
    /// writes its marker and drops the drained source directory. See `AlbumManager`.
    @discardableResult func finalizeMigrationToCloudKit(album: Album, albumID: String) throws -> Album
    /// Completes a whole CloudKit album's move back to local storage once the engine
    /// has copied and verified every item and removed every record: drops the album
    /// record and this device's CloudKit identity for the album. `movedRecordNames`
    /// are the records the move brought home and removed; any other member of the
    /// album makes it refuse. See `AlbumManager`.
    @discardableResult func finalizeMigrationToLocal(album: Album, movedRecordNames: Set<String>) async throws -> Album
    func renameAlbum(album: Album, to newName: String) throws -> Album
    func validateAlbumName(name: String) throws
    func albumMediaCount(album: Album) -> Int
    func isAlbumHidden(_ album: Album) -> Bool
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album)
    /// Materializes a CloudKit album discovered by the album reconciler (marker,
    /// hidden state, broadcasts) so remote discovery goes through the manager —
    /// keeping `albumOperationPublisher` observers and `currentAlbum` consistent —
    /// instead of mutating the filesystem behind its back. `record` is the album's
    /// `EncAlbum` record and `key` the key proven to open its `encName`.
    func adoptCloudKitAlbum(record: CloudKitAlbumMetadata, key: PrivateKey)
    var lockedAlbums: [LockedAlbumPlaceholder] { get }

    /// Rescans the filesystem and broadcasts the updated album list.
    func notifyAlbumsChanged()
}

/// How far an album move has got: `completed` of `total` files handled, whether
/// they moved or stayed behind.
public struct AlbumMoveProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var fractionComplete: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

public extension AlbumManaging {

    /// `moveAlbum` without progress reporting.
    func moveAlbum(album: Album, toStorage: StorageType) async throws -> Album {
        try await moveAlbum(album: album, toStorage: toStorage, onProgress: { _ in })
    }
    /// Default: delegates to the full `delete` for conformers that don't need a
    /// local-only path (previews, test doubles).
    func applyRemoteAlbumDeletion(album: Album) {
        try? delete(album: album)
    }

    /// Default no-op for lightweight conformers (previews, test doubles).
    func notifyAlbumsChanged() {}
    func fetchAlbumsFromSources() -> [Album] {
        fetchAlbumsFromSources(includingHidden: false)
    }

    /// Another album on this device already called `name`, in any storage and hidden
    /// or not. Album names are unique per device only; two devices can still make
    /// same-named albums while offline.
    func albumNamed(_ name: String, otherThan album: Album) -> Album? {
        fetchAlbumsFromSources(includingHidden: true).first { $0.name == name && $0.id != album.id }
    }

    /// Default flip used by non-broadcasting conformers (previews/test doubles):
    /// write `album.json` with the source's hidden flag and cover (unless the album
    /// is already on this device) and drop the drained source directory.
    /// `AlbumManager` overrides this to also push the record, remove the source's
    /// name-keyed settings and broadcast the change.
    @discardableResult
    func finalizeMigrationToCloudKit(album: Album, albumID: String) throws -> Album {
        let cloudKitAlbum = Album.cloudKitTwin(of: album, albumID: albumID)
        if !CloudKitAlbumMarker.exists(albumID: albumID) {
            try CloudKitAlbumMarker(album: cloudKitAlbum,
                                    isHidden: isAlbumHidden(album),
                                    coverMediaID: getAlbumCoverImageId(album: album)).write(albumID: albumID)
        }
        guard CloudKitAlbumMarker.exists(albumID: albumID) else {
            throw AlbumError.cloudKitMarkerWriteFailed
        }
        if album.storageOption != .cloudKit {
            let sourceModel = album.storageOption.modelForType.init(album: album)
            Album.removeDrainedSourceDirectory(at: sourceModel.baseURL)
        }
        return cloudKitAlbum
    }

    /// Default flip used by non-broadcasting conformers (previews/test doubles):
    /// remove the CloudKit discovery marker so the local album is discovered.
    /// `AlbumManager` overrides this to also delete the album record and broadcast.
    @discardableResult
    func finalizeMigrationToLocal(album: Album, movedRecordNames: Set<String>) async throws -> Album {
        if let albumID = album.albumID {
            try CloudKitAlbumMarker.remove(albumID: albumID)
        }
        return Album.localTwin(of: album)
    }

    /// Whether a CloudKit album with this album's name and key exists on this
    /// device — i.e. whether a migration actually finalized. A CloudKit album's id is
    /// not derivable from its name, so this scans the `album.json` markers
    /// `finalizeMigrationToCloudKit` writes (and `fetchAlbumsFromSources` derives its
    /// `.cloudKit` albums from) for an `encName` that decrypts under the album's key
    /// to its name. It is the one true answer to "did this album really move",
    /// available to callers outside this module that must not report a migration
    /// they did not achieve. Before finalize there is no marker, so it is false.
    func hasFinalizedToCloudKit(album: Album) -> Bool {
        CloudKitAlbumMarker.albumID(matching: album) != nil
    }

    /// Default no-op so lightweight test/demo conformers need not implement it.
    func adoptCloudKitAlbum(record: CloudKitAlbumMetadata, key: PrivateKey) {}

    /// Default empty: conformers that don't track locked albums return none.
    var lockedAlbums: [LockedAlbumPlaceholder] { [] }

    /// Falls `album` back to its default cover when its cover is `mediaID`, the item
    /// that has just left it. A cover the user turned off stays off.
    func resetAlbumCover(album: Album, ifItIs mediaID: String) {
        guard getAlbumCoverImageId(album: album) == mediaID else { return }
        resetAlbumCover(album: album)
    }
}
