//
//  MockAlbumManager.swift
//  EncameraCoreTests
//
//  Minimal AlbumManaging for FileAccess tests: just enough to satisfy
//  the preview pipeline (key access + storage model).
//

import Foundation
import Combine
import UIKit
@testable import EncameraCore

final class MockAlbumManager: AlbumManaging {

    var keyManager: KeyManager
    var defaultStorageForAlbum: StorageType = .local
    var currentAlbum: Album?
    var currentAlbumMediaCount: Int? { nil }
    var albumsOnDisk: [Album] = []

    private(set) var deletedAlbums: [Album] = []
    private(set) var remoteDeletedAlbums: [Album] = []
    private(set) var adoptedAlbums: [(name: String, isHidden: Bool, albumID: String, encName: String)] = []
    private(set) var setHiddenCalls: [(name: String, isHidden: Bool)] = []
    var hiddenAlbumNames: Set<String> = []
    private(set) var notifyAlbumsChangedCount = 0

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    required init(keyManager: KeyManager, syncedDataStore: SyncedDataStore?) {
        self.keyManager = keyManager
    }

    var albumOperationPublisher: AnyPublisher<AlbumOperation, Never> {
        Empty().eraseToAnyPublisher()
    }

    func storageModel(for album: Album) -> DataStorageModel? {
        album.storageOption.modelForType.init(album: album)
    }

    func delete(album: Album) {
        deletedAlbums.append(album)
        albumsOnDisk.removeAll { $0.name == album.name }
    }
    func applyRemoteAlbumDeletion(album: Album) {
        remoteDeletedAlbums.append(album)
        albumsOnDisk.removeAll { $0.name == album.name }
    }
    func adoptCloudKitAlbum(record: CloudKitAlbumMetadata, key: PrivateKey) {
        let album = Album(encryptedName: record.encName, storageOption: .cloudKit,
                          creationDate: record.createdAt, key: key, albumID: record.albumID)
        adoptedAlbums.append((name: album.name, isHidden: record.isHidden,
                              albumID: record.albumID, encName: record.encName))
        albumsOnDisk.append(album)
    }
    /// Each album's chosen cover by `Album.id`: a media id, or `"none"` when turned off.
    var coverImageIDs: [String: String] = [:]
    private(set) var resetCoverCalls: [Album] = []
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {
        coverImageIDs[album.id] = image.id
    }
    func removeAlbumCover(album: Album) { coverImageIDs[album.id] = "none" }
    func resetAlbumCover(album: Album) {
        resetCoverCalls.append(album)
        coverImageIDs[album.id] = nil
    }
    func getAlbumCoverImageId(album: Album) -> String? { coverImageIDs[album.id] }
    func isAlbumCoverImageDisabled(album: Album) -> Bool { coverImageIDs[album.id] == "none" }
    /// Albums returned only when the caller asks for hidden ones, so a test can prove
    /// a reader passes `includingHidden: true` rather than trusting it does.
    var hiddenAlbumsOnDisk: [Album] = []
    private(set) var fetchIncludingHiddenCalls: [Bool] = []

    func fetchAlbumsFromSources(includingHidden: Bool) -> [Album] {
        fetchIncludingHiddenCalls.append(includingHidden)
        return includingHidden ? albumsOnDisk + hiddenAlbumsOnDisk : albumsOnDisk
    }
    func restoreCurrentAlbumFromUserDefaults() {}
    func notifyAlbumsChanged() { notifyAlbumsChangedCount += 1 }
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album {
        Album(name: name, storageOption: storageOption, creationDate: Date(), key: keyManager.currentKey!,
              albumID: storageOption == .cloudKit ? UUID().uuidString : nil)
    }
    func moveAlbum(album: Album, toStorage: StorageType, onProgress: @escaping @Sendable (AlbumMoveProgress) -> Void) async throws -> Album { album }

    private(set) var finalizeCallCount = 0
    private(set) var finalizedAlbums: [Album] = []
    /// Set to make `finalizeMigrationToCloudKit` throw (e.g. the marker write
    /// failing), so tests can exercise the kept-checkpoint retry path.
    var finalizeError: Error?
    func finalizeMigrationToCloudKit(album: Album, albumID: String) throws -> Album {
        finalizeCallCount += 1
        if let finalizeError { throw finalizeError }
        let cloudKitAlbum = Album.cloudKitTwin(of: album, albumID: albumID)
        finalizedAlbums.append(cloudKitAlbum)
        try? CloudKitAlbumMarker(album: cloudKitAlbum, isHidden: false).write(albumID: albumID)
        let sourceModel = album.storageOption.modelForType.init(album: album)
        Album.removeDrainedSourceDirectory(at: sourceModel.baseURL)
        return cloudKitAlbum
    }
    private(set) var finalizeToLocalCallCount = 0
    /// Set to make `finalizeMigrationToLocal` throw, so tests can exercise the
    /// kept-checkpoint retry path.
    var finalizeToLocalError: Error?
    func finalizeMigrationToLocal(album: Album) async throws -> Album {
        finalizeToLocalCallCount += 1
        if let finalizeToLocalError { throw finalizeToLocalError }
        if let albumID = album.albumID {
            try? CloudKitAlbumMarker.remove(albumID: albumID)
        }
        return Album.localTwin(of: album)
    }
    func renameAlbum(album: Album, to newName: String) throws -> Album { album }
    func validateAlbumName(name: String) throws {}
    func albumMediaCount(album: Album) -> Int { 0 }
    func isAlbumHidden(_ album: Album) -> Bool { hiddenAlbumNames.contains(album.name) }
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        setHiddenCalls.append((name: album.name, isHidden: isAlbumHidden))
        if isAlbumHidden { hiddenAlbumNames.insert(album.name) } else { hiddenAlbumNames.remove(album.name) }
    }
}
