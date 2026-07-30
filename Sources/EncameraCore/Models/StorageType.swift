//
//  StorageType.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation

public struct StorageAvailabilityModel: Identifiable, Equatable {
    public let storageType: StorageType
    public let availability: StorageType.Availability
    public var id: StorageType {
        storageType
    }
}

public enum StorageType: String, Codable {
    case icloud
    case local
    /// CloudKit-backed storage (the user's private CloudKit database). Coexists
    /// with `.icloud` (iCloud Drive) during migration; becomes "iCloud" to the
    /// user once iCloud Drive is removed (chunk 07).
    case cloudKit

    public enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    public var modelForType: DataStorageModel.Type {
        switch self {
        case .icloud:
            return iCloudStorageModel.self
        case .local:
            return LocalStorageModel.self
        case .cloudKit:
            return CloudKitStorageModel.self
        }
    }


}

extension StorageType: Identifiable, CaseIterable {
    public var id: Self { self }
    /// Labels for `.icloud` and `.cloudKit` must stay distinct for as long as the two
    /// coexist: they are simultaneously visible during migration, and a user (or a UI
    /// test) has to be able to tell them apart. `.cloudKit` keeps the plain "iCloud"
    /// wording because it is the destination; deprecated iCloud Drive carries the
    /// "(Legacy)" qualifier. `StorageTypeTests.testStorageTypeLabelsAreUnique` locks
    /// this closed over every case.
    public var title: String {
        switch self {
        case .icloud:
            return L10n.StorageType.iCloudDriveLegacyTitle
        case .local:
            return L10n.local
        case .cloudKit:
            // To the user this is simply "iCloud"; once iCloud Drive is removed
            // entirely the `.icloud` case goes with it and this stays as-is.
            return "iCloud"
        }
    }

    public var iconName: String {
        switch self {
        case .icloud:
            return "externaldrive.badge.icloud"
        case .local:
            return "lock.iphone"
        case .cloudKit:
            return "lock.icloud"
        }
    }

    public var description: String {
        switch self {
        case .icloud:
            return L10n.saveToiCloudDrive
        case .local:
            return L10n.saveLocally
        case .cloudKit:
            return L10n.StorageType.saveToICloud
        }
    }

    /// A human-readable location name for contextual display (e.g., "3 files on iCloud").
    public var locationName: String {
        switch self {
        case .icloud:
            return L10n.StorageType.iCloudDriveLegacyLocationName
        case .local:
            return L10n.localDevice
        case .cloudKit:
            return "iCloud"
        }
    }

}
