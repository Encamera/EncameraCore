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

    // Instrumentation for reconciler tests
    private(set) var deletedAlbums: [Album] = []
    private(set) var adoptedAlbums: [(name: String, isHidden: Bool)] = []
    private(set) var setHiddenCalls: [(name: String, isHidden: Bool)] = []
    var hiddenAlbumNames: Set<String> = []

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
    func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool) {
        adoptedAlbums.append((name: name, isHidden: isHidden))
        albumsOnDisk.append(Album(name: name, storageOption: .cloudKit, creationDate: createdAt, key: key))
    }
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>) {}
    func removeAlbumCover(album: Album) {}
    func resetAlbumCover(album: Album) {}
    func getAlbumCoverImageId(album: Album) -> String? { nil }
    func isAlbumCoverImageDisabled(album: Album) -> Bool { false }
    func fetchAlbumsFromSources(includingHidden: Bool) -> [Album] { albumsOnDisk }
    func restoreCurrentAlbumFromUserDefaults() {}
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album {
        Album(name: name, storageOption: storageOption, creationDate: Date(), key: keyManager.currentKey!)
    }
    func moveAlbum(album: Album, toStorage: StorageType) throws -> Album { album }
    func renameAlbum(album: Album, to newName: String) throws -> Album { album }
    func validateAlbumName(name: String) throws {}
    func albumMediaCount(album: Album) -> Int { 0 }
    func isAlbumHidden(_ album: Album) -> Bool { hiddenAlbumNames.contains(album.name) }
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album) {
        setHiddenCalls.append((name: album.name, isHidden: isAlbumHidden))
        if isAlbumHidden { hiddenAlbumNames.insert(album.name) } else { hiddenAlbumNames.remove(album.name) }
    }
}
