//
//  CloudKitFileAccessDependencyInjection.swift
//  EncameraCore
//
//  Seams that exist so tests can swap out what `CloudKitFileAccess` and the
//  CloudKit sync stack reach: the CloudKit store and the album's linked iCloud
//  Drive folder. Each defaults to the production implementation, so the app never
//  sets them; unit tests pass doubles at construction and UI tests bind them from
//  `UITestSupport`.
//

import Foundation

/// Supplies the `CloudKitMediaStoring` implementation. Production returns the real
/// store; UI tests bind a deterministic in-memory mock via `UITestSupport`.
public enum CloudKitStoreProvider {
    /// `purpose` names the caller, for a test double that wants to tell callers
    /// apart. It has no effect on the store: every store shares the zone's one
    /// change cursor.
    ///
    /// Binding a new factory drops the shared coordinator, so the next one is built
    /// on the store this factory makes.
    nonisolated(unsafe) public static var makeStore: @Sendable (_ purpose: String) -> CloudKitMediaStoring = { _ in
        CloudKitMediaStore()
    } {
        didSet {
            isMakeStoreBound = true
            CloudKitSyncCoordinator.resetShared()
        }
    }

    /// Whether `makeStore` has been bound to another factory.
    nonisolated(unsafe) static var isMakeStoreBound = false

    /// Builds the real store for a network policy. Tests replace it to read the
    /// policy a store was given without reaching CloudKit.
    nonisolated(unsafe) static var makePolicyStore: @Sendable (_ networkPolicy: @escaping @Sendable () -> CloudKitNetworkPolicy) -> CloudKitMediaStoring = {
        CloudKitMediaStore(networkPolicy: $0)
    }

    /// A store whose CloudKit requests run under `networkPolicy`, read per
    /// request. A bound `makeStore` factory, such as a test's or the UI-test
    /// mock's, is used as it is, without the policy.
    public static func makeStore(_ purpose: String,
                                 networkPolicy: @escaping @Sendable () -> CloudKitNetworkPolicy) -> CloudKitMediaStoring {
        isMakeStoreBound ? makeStore(purpose) : makePolicyStore(networkPolicy)
    }

    /// A store for the iCloud Drive to CloudKit migration: its requests run under
    /// `ICloudDriveBlobMigration.networkPolicy`, so they never use cellular. A
    /// bound `makeStore` factory is used as it is.
    public static func makeMigrationStore(_ purpose: String) -> CloudKitMediaStoring {
        makeStore(purpose, networkPolicy: { ICloudDriveBlobMigration.networkPolicy })
    }
}

/// How a CloudKit album reaches the iCloud Drive folder its local marker links
/// to, where components not yet in CloudKit, or not yet deleted after reaching
/// it, still have their files.
///
/// Every member defaults to the real file system and iCloud Drive; production
/// always uses `CloudKitICloudDriveFolderAccess()`. Tests replace members to
/// stand in a folder, its download state and the materializer, since no test
/// host has a ubiquity container.
public struct CloudKitICloudDriveFolderAccess: Sendable {
    var isICloudDriveAvailable: @Sendable () -> Bool = { iCloudStorageModel.isRootAvailable }
    var linkedFolder: @Sendable (String) -> URL? = { CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: $0) }
    var markerConflictVersions: @Sendable (URL) -> [URL] = { ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of: $0) }
    /// Whether a file's bytes are on this device, rather than only in iCloud.
    var isDownloaded: @Sendable (URL) -> Bool = { ICloudPlaceholderName.isMaterialized($0) }
    /// Whether a file is there at all, downloaded or as a placeholder.
    var existsInAnyForm: @Sendable (URL) -> Bool = { ICloudPlaceholderName.existsInAnyForm($0) }
    /// Downloads evicted files.
    var makeMaterializer: @MainActor @Sendable () -> any ICloudDriveMaterializing
    /// Finds and removes a deleted item's file in the folder, in either form.
    var fileSystem: ICloudDriveVerifiedDeleteFileSystem = ICloudDriveVerifiedDeleteDiskFileSystem()
    /// Ends the album's move once a delete leaves nothing of it to move.
    var makeAlbumFinish: @MainActor @Sendable (AlbumManaging) -> ICloudDriveAlbumFinish = { ICloudDriveAlbumFinish(albumManager: $0) }
    /// Moves a media item ahead of the album's other items still to migrate, and
    /// clears a deferral of its move the decrypt disproves, for an open in the
    /// viewer or player that decrypted an item still on iCloud Drive.
    var prioritizeViewed: @Sendable (_ album: Album, _ mediaID: String) async -> Void = { album, mediaID in
        guard let albumID = album.albumID,
              MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: albumID) else { return }
        let store = MigrationPlanStore(iCloudDriveMigrationFrom: album, cloudKitAlbumID: albumID)
        guard let plan = await store.load() else { return }
        let items = plan.items.filter { $0.mediaID == mediaID }
        guard !items.isEmpty else { return }
        _ = try? await store.prioritizeViewed(items)
    }
    /// Starts a blob migration pass for the CloudKit album unless one is running,
    /// without waiting for it, so an item a viewer open prioritized moves now
    /// rather than at whichever pass would have come next. The pass keeps the
    /// blob migration's own conditions.
    var startMigrationPass: @MainActor @Sendable (_ albumManager: AlbumManaging, _ albumID: String) async -> Void = { albumManager, albumID in
        await ICloudDriveBlobMigration.startPass(albumManager: albumManager, albumID: albumID)
    }

    /// - Parameter makeMaterializer: what downloads an evicted file. A test
    ///   passes a fake: no test host has a ubiquity container.
    public init(makeMaterializer: @escaping @MainActor @Sendable () -> any ICloudDriveMaterializing = { ICloudDriveMaterializer() }) {
        self.makeMaterializer = makeMaterializer
    }
}
