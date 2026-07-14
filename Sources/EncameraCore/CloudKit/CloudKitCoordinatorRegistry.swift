//
//  CloudKitCoordinatorRegistry.swift
//  EncameraCore
//
//  One `CloudKitSyncCoordinator` per album id, shared across the active album's
//  `CloudKitFileAccess` and the push fan-out (`CloudKitAlbumsSync`). Without this,
//  the fan-out would build ephemeral coordinators that update the on-disk index but
//  not the live coordinator's in-memory `changeTags`/`deletedRecordNames`, so the
//  active instance could serve stale blobs or miss cross-device tombstones.
//

import Foundation

public actor CloudKitCoordinatorRegistry {

    public static let shared = CloudKitCoordinatorRegistry()

    private var coordinators: [String: CloudKitSyncCoordinator] = [:]

    public init() {}

    /// The coordinator for `albumID`, creating it via `make` on first request and
    /// reusing the same instance thereafter.
    public func coordinator(forAlbumID albumID: String,
                            make: () -> CloudKitSyncCoordinator) -> CloudKitSyncCoordinator {
        if let existing = coordinators[albumID] { return existing }
        let created = make()
        coordinators[albumID] = created
        return created
    }
}
