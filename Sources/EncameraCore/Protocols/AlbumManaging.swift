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
    func delete(album: Album)
    func setAlbumCoverImage(album: Album, image: InteractableMedia<EncryptedMedia>)
    func removeAlbumCover(album: Album)
    func resetAlbumCover(album: Album)
    func getAlbumCoverImageId(album: Album) -> String?
    func isAlbumCoverImageDisabled(album: Album) -> Bool
    func fetchAlbumsFromSources(includingHidden: Bool) -> [Album]
    func restoreCurrentAlbumFromUserDefaults()
    @discardableResult func create(name: String, storageOption: StorageType) throws -> Album
    func storageModel(for album: Album) -> DataStorageModel?
    func moveAlbum(album: Album, toStorage: StorageType) throws -> Album
    func renameAlbum(album: Album, to newName: String) throws -> Album
    func validateAlbumName(name: String) throws
    func albumMediaCount(album: Album) -> Int
    func isAlbumHidden(_ album: Album) -> Bool
    func setIsAlbumHidden(_ isAlbumHidden: Bool, album: Album)
    /// Materializes a CloudKit album discovered by the album reconciler (marker,
    /// hidden state, broadcasts) so remote discovery goes through the manager —
    /// keeping `albumOperationPublisher` observers and `currentAlbum` consistent —
    /// instead of mutating the filesystem behind its back.
    func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool)
}

public extension AlbumManaging {
    func fetchAlbumsFromSources() -> [Album] {
        fetchAlbumsFromSources(includingHidden: false)
    }

    /// Default no-op so lightweight test/demo conformers need not implement it.
    func adoptCloudKitAlbum(name: String, key: PrivateKey, createdAt: Date, isHidden: Bool) {}
}
