//
//  CloudKitAlbumsSync.swift
//  EncameraCore
//
//  App-level fan-out for CloudKit pushes: a per-album `CloudKitFileAccess` only
//  delta-syncs the album it was configured for, so inactive CloudKit albums (e.g.
//  while the album grid is shown) would never refresh on a push. This observes
//  `cloudKitZoneChanged` and reconciles every CloudKit album.
//

import Foundation

public actor CloudKitAlbumsSync {

    private let albumManager: AlbumManaging
    /// Builds the album-existence reconciler (chunk 13). Injectable so tests can
    /// supply a deterministic in-memory store; production uses the shared provider.
    private let makeReconciler: @Sendable (AlbumManaging) -> CloudKitAlbumReconciler
    private var observer: NSObjectProtocol?

    /// The most recent count of remote albums that could not be materialized for lack
    /// of a synced key (key backup off). The UI reads this to prompt "N albums need
    /// key backup to appear here".
    public private(set) var albumsNeedingKey: Int = 0

    /// Single-flight: a CK push landing at the same moment as scene-active used to
    /// run two overlapping full reconciles (and race `albumsNeedingKey`, then a
    /// plain Int on an @unchecked Sendable class). Overlapping callers now join the
    /// in-flight run, like `CloudKitSyncCoordinator` — and, like the coordinator,
    /// a join flags `resyncRequested` so a push landing mid-run (possibly after
    /// `fetchAllAlbums`/`reconcile` already passed) is honored by one extra pass
    /// instead of silently dropped until the next trigger.
    private var activeSync: Task<Void, Never>?
    /// Internal (not private) so tests can observe that a joiner's request landed.
    private(set) var resyncRequested = false

    public init(albumManager: AlbumManaging,
                observeNotifications: Bool = true,
                makeReconciler: (@Sendable (AlbumManaging) -> CloudKitAlbumReconciler)? = nil) {
        self.albumManager = albumManager
        self.makeReconciler = makeReconciler ?? { albumManager in
            CloudKitAlbumReconciler(store: CloudKitStoreProvider.makeStore(""),
                                    keyManager: albumManager.keyManager,
                                    albumManager: albumManager)
        }
        if observeNotifications {
            observer = NotificationCenter.default.addObserver(
                forName: .cloudKitZoneChanged, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.syncAll() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// First reconcile album *existence* from CloudKit (materialize newly-discovered
    /// albums, remove tombstoned ones, push local-only ones up), THEN reconcile each
    /// CloudKit album's media index — so a newly materialized album is included in the
    /// same pass. Local/iCloud-Drive albums are ignored throughout. Overlapping calls
    /// coalesce into the in-flight run.
    public func syncAll() async {
        if let active = activeSync {
            resyncRequested = true
            await active.value
            return
        }
        let task = Task {
            // Cleared inside the task, in the same synchronous stretch as
            // drainSyncAll's final `resyncRequested` check — a joiner either sees
            // the task (its flag is honored by the loop) or starts a fresh sync.
            defer { activeSync = nil }
            await drainSyncAll()
        }
        activeSync = task
        await task.value
    }

    private func drainSyncAll() async {
        repeat {
            resyncRequested = false
            await performSyncAll()
        } while resyncRequested
    }

    private func performSyncAll() async {
        // Skip the container entirely when the CloudKit plane is inactive: flag off
        // AND no `.cloudKit` albums exist locally (albums from a previous flag-on
        // period keep syncing). Without this, every scene-active hits the live
        // container for the vast majority of users, and the reconciler's self-heal
        // push has no flag check of its own.
        let hasCloudKitAlbums = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .contains { $0.storageOption == .cloudKit }
        guard FeatureToggle.isEnabled(feature: .cloudKitStorage) || hasCloudKitAlbums else { return }

        albumsNeedingKey = await makeReconciler(albumManager).reconcileAlbums()

        // Re-fetch: the reconciler may have materialized or removed albums.
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
            .filter { $0.storageOption == .cloudKit }
        for album in albums {
            let access = await CloudKitFileAccess(album: album, albumManager: albumManager)
            _ = await access.reconcile()
        }
    }
}
