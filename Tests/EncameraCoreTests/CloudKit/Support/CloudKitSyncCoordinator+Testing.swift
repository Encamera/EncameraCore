//
//  CloudKitSyncCoordinator+Testing.swift
//  EncameraCoreTests
//
//  Builds a coordinator over a `MockAlbumManager` holding the given CloudKit
//  albums, each with the index store (and size sidecar) the test hands in.
//

import Foundation
@testable import EncameraCore

extension CloudKitSyncCoordinator {

    /// A coordinator whose albums are `albums`: album id → its index store and
    /// optional size sidecar. The returned manager is the one the coordinator
    /// reads, so a test can add albums to it later.
    static func forTesting(albums: [(id: String, index: MediaIndexStore, sizeSidecar: AlbumSizeSidecar?)],
                           store: CloudKitMediaStoring,
                           cache: CloudKitBlobCache,
                           bus: FileOperationBus = .shared,
                           uploadQueue: CloudKitUploadQueue = .shared,
                           deleteQueue: CloudKitMediaDeleteQueue = CloudKitMediaDeleteQueue(),
                           chunkStore: ChunkedBlobStoring? = nil) -> (CloudKitSyncCoordinator, MockAlbumManager) {
        let albumManager = MockAlbumManager(keyManager: DemoKeyManager())
        for album in albums {
            albumManager.addCloudKitAlbum(album.id, indexStore: album.index, sizeSidecar: album.sizeSidecar)
        }
        let coordinator = CloudKitSyncCoordinator(store: store,
                                                  cache: cache,
                                                  albumManager: albumManager,
                                                  bus: bus,
                                                  uploadQueue: uploadQueue,
                                                  deleteQueue: deleteQueue,
                                                  chunkStore: chunkStore)
        return (coordinator, albumManager)
    }

    /// A coordinator over the single CloudKit album `albumID`, whose index is
    /// `indexStore`.
    static func forTesting(albumID: String,
                           store: CloudKitMediaStoring,
                           cache: CloudKitBlobCache,
                           indexStore: MediaIndexStore,
                           sizeSidecar: AlbumSizeSidecar? = nil,
                           bus: FileOperationBus = .shared,
                           uploadQueue: CloudKitUploadQueue = .shared,
                           deleteQueue: CloudKitMediaDeleteQueue = CloudKitMediaDeleteQueue(),
                           chunkStore: ChunkedBlobStoring? = nil) -> CloudKitSyncCoordinator {
        forTesting(albums: [(albumID, indexStore, sizeSidecar)],
                   store: store, cache: cache, bus: bus, uploadQueue: uploadQueue,
                   deleteQueue: deleteQueue, chunkStore: chunkStore).0
    }
}
