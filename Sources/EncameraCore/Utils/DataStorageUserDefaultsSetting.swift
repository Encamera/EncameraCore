//
//  ImageKeyDirectoryStorage.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

public struct DataStorageAvailabilityUtil {

    public static var preselectedStorageSetting: StorageAvailabilityModel? {
        storageAvailabilities().filter({$0.availability == .available}).first
    }

    /// Whether the storage backend is usable on this device *right now* — i.e. whether
    /// existing albums there can be enumerated, read, and deleted.
    ///
    /// This is deliberately NOT the same question as "may a new album be put here":
    /// iCloud Drive is deprecated as a destination once CloudKit is on, but the albums
    /// a user already has in iCloud Drive must keep showing up in the album list until
    /// they migrate them. Destination eligibility lives in
    /// `isStorageTypeOfferedForNewAlbums` and the pickers that read it.
    public static func isStorageTypeAvailable(type: StorageType) -> StorageType.Availability {
        switch type {
        case .icloud:
            if FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: L10n.noICloudAccountFoundOnThisDevice)
            } else {
                return .available
            }
        case .local:
            return .available
        case .cloudKit:
            // Offered only when the feature flag is on AND an iCloud account is
            // present. A CloudKit account implies the ubiquity token exists, so we
            // reuse that synchronous signal (same one iCloud Drive checks) rather
            // than threading async account-status through every availability site.
            guard FeatureToggle.isEnabled(feature: .cloudKitStorage) else {
                return .unavailable(reason: "CloudKit storage is not enabled")
            }
            // UI tests force account availability so the picker can be exercised
            // offline (the in-memory mock store backs the coordinator). Gated on
            // -UITestMode like every other test hook, so the flag stays inert in
            // production — without it, a stray argument would offer CloudKit with
            // no iCloud account and every subsequent save would fail.
            let arguments = ProcessInfo.processInfo.arguments
            let accountForcedAvailable = arguments.contains("-UITestMode")
                && arguments.contains("-CloudKitAccountAvailable")
            if !accountForcedAvailable, FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: L10n.noICloudAccountFoundOnThisDevice)
            }
            return .available
        }
    }
    
    /// Whether a *new* album may be created in (or moved into) this storage type.
    ///
    /// Narrower than `isStorageTypeAvailable`: iCloud Drive is a dead end once
    /// CloudKit is active, so it is never offered as a destination even though its
    /// existing albums stay fully readable. `AlbumManager.create`/`moveAlbum` enforce
    /// the same rule as the authoritative backstop.
    public static func isStorageTypeOfferedForNewAlbums(type: StorageType) -> StorageType.Availability {
        if type == .icloud, FeatureToggle.isEnabled(feature: .cloudKitStorage) {
            return .unavailable(reason: "iCloud Drive storage is not enabled")
        }
        return isStorageTypeAvailable(type: type)
    }

    /// The destination options shown by the storage pickers, so every picker inherits
    /// the iCloud Drive deprecation rule from one place.
    public static func storageAvailabilities() -> [StorageAvailabilityModel] {
        var availabilites = [StorageAvailabilityModel]()
        for type in StorageType.allCases {
            let result = isStorageTypeOfferedForNewAlbums(type: type)
            availabilites += [StorageAvailabilityModel(storageType: type, availability: result)]
        }
        return availabilites
    }
}
