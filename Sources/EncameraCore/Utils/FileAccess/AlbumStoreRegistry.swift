//
//  AlbumStoreRegistry.swift
//  EncameraCore
//
//  The one `MediaIndexStore` and the one `AlbumSizeSidecar` per album, for the
//  whole process. `AlbumManager` fronts it (`mediaIndexStore(for:)`,
//  `sizeSidecar(for:)`), and nothing else constructs either for an album.
//
//  Each store serializes its own writes, so two stores for one album race: both
//  load the same file, both fold in their change, and the later save drops the
//  earlier one. Handing every caller the same instance closes that. The map lives
//  here rather than on `AlbumManager` because the app builds a new manager each
//  time the key becomes available, and every one of them must hand out the same
//  store.
//

import Foundation

public final class AlbumStoreRegistry: @unchecked Sendable, DebugPrintable {

    public static let shared = AlbumStoreRegistry()

    private let lock = NSLock()
    /// Keyed by `Album.id`, which is also what names the files on disk.
    private var indexStores: [String: MediaIndexStore] = [:]
    private var sizeSidecars: [String: AlbumSizeSidecar] = [:]

    public init() {}

    /// The album's index store, created on first request.
    public func indexStore(for album: Album) -> MediaIndexStore {
        lock.withLock {
            if let existing = indexStores[album.id] { return existing }
            let created = MediaIndexStore(album: album)
            indexStores[album.id] = created
            return created
        }
    }

    /// The album's size sidecar, created on first request.
    public func sizeSidecar(for album: Album) -> AlbumSizeSidecar {
        lock.withLock {
            if let existing = sizeSidecars[album.id] { return existing }
            let created = AlbumSizeSidecar(album: album)
            sizeSidecars[album.id] = created
            return created
        }
    }

    /// The index store already handed out for the CloudKit album `albumID`, if any.
    /// Never creates one: building a store needs the album's key.
    public func existingIndexStore(forCloudKitAlbumID albumID: String) -> MediaIndexStore? {
        lock.withLock { indexStores[Self.cloudKitAlbumKey(albumID)] }
    }

    /// The size sidecar already handed out for the CloudKit album `albumID`, if any.
    public func existingSizeSidecar(forCloudKitAlbumID albumID: String) -> AlbumSizeSidecar? {
        lock.withLock { sizeSidecars[Self.cloudKitAlbumKey(albumID)] }
    }

    /// Forgets the album's stores, so the next request builds them from what is on
    /// disk. Called when the album is deleted, leaves its storage, or takes a new id.
    public func drop(albumWithID id: String) {
        let dropped = lock.withLock {
            let had = indexStores.removeValue(forKey: id) != nil
            return sizeSidecars.removeValue(forKey: id) != nil || had
        }
        if dropped {
            printDebug("drop ok album=\(id)")
        }
    }

    /// `Album.id` of the CloudKit album whose record id is `albumID`.
    private static func cloudKitAlbumKey(_ albumID: String) -> String {
        "\(albumID)_\(StorageType.cloudKit.rawValue)"
    }
}
