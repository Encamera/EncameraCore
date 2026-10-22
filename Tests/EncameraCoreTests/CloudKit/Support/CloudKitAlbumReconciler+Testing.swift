//
//  CloudKitAlbumReconciler+Testing.swift
//  EncameraCoreTests
//
//  The reconciler no longer reads the zone change feed; the coordinator's walk
//  hands it the album part. This does the same around a reconcile, against the
//  reconciler's own store, for tests that drive the reconciler alone.
//

import Foundation
@testable import EncameraCore

extension CloudKitAlbumReconciler {

    /// Walks the store's change feed from its cursor the way
    /// `CloudKitSyncCoordinator.sync` does, reconciles with the album part, and
    /// commits the cursor after. A walk that fails reconciles with no changes, as
    /// `CloudKitAlbumsSync` does.
    @discardableResult
    func reconcileAlbumsAfterWalk() async -> CloudKitAlbumReconcileResult {
        guard await store.accountAvailable() else {
            return await reconcileAlbums(changes: .none)
        }
        var token = await store.loadChangeToken()
        var changedAlbums: [CloudKitAlbumMetadata] = []
        var deletedAlbumIDs: [String] = []
        do {
            var moreComing = true
            while moreComing {
                let changeSet = try await store.fetchChanges(since: token)
                if changeSet.token != nil { token = changeSet.token }
                moreComing = changeSet.moreComing
                changedAlbums += changeSet.changedAlbums
                deletedAlbumIDs += changeSet.deletedAlbumIDs
            }
        } catch {
            return await reconcileAlbums(changes: .none)
        }
        let result = await reconcileAlbums(changes: CloudKitAlbumChanges(changedAlbums: changedAlbums,
                                                                         deletedAlbumIDs: deletedAlbumIDs))
        await store.commitChangeToken(token)
        return result
    }
}
