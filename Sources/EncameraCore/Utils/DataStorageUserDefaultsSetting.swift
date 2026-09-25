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
    /// existing albums there can be enumerated, read, written to, and deleted.
    ///
    /// This is deliberately NOT the same question as "may a new album be put here":
    /// iCloud Drive is deprecated as a destination, but the albums a user already has
    /// in iCloud Drive must keep showing up in the album list — and stay fully
    /// writable — until they migrate them. Destination eligibility lives in
    /// `isStorageTypeOfferedForNewAlbums` and the pickers that read it.
    public static func isStorageTypeAvailable(type: StorageType) -> StorageType.Availability {
        switch type {
        case .icloud:
            if iCloudStorageModel.testContainerRootOverride == nil,
               FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: L10n.noICloudAccountFoundOnThisDevice)
            }
            return .available
        case .local:
            return .available
        case .cloudKit:
            guard FeatureToggle.isEnabled(feature: .cloudKitStorage) else {
                return .unavailable(reason: "CloudKit storage is not enabled")
            }
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
    /// Narrower than `isStorageTypeAvailable`: iCloud Drive is a dead end, so it is
    /// never offered as a destination even though its existing albums stay fully
    /// readable and writable. `AlbumManager.create`/`moveAlbum` enforce the same rule
    /// as the authoritative backstop.
    public static func isStorageTypeOfferedForNewAlbums(type: StorageType) -> StorageType.Availability {
        if type == .icloud {
            return .unavailable(reason: "iCloud Drive storage is deprecated")
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
