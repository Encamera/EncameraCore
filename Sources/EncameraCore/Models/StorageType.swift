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
    public var title: String {
        switch self {
        case .icloud:
            return "iCloud"
        case .local:
            return L10n.local
        case .cloudKit:
            // To the user this is simply "iCloud"; legacy `.icloud` is distinguished
            // only in debug/migration surfaces during coexistence.
            return "iCloud"
        }
    }

    public var iconName: String {
        switch self {
        case .icloud:
            return "lock.icloud"
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
            return L10n.saveToiCloudDrive
        }
    }

    /// A human-readable location name for contextual display (e.g., "3 files on iCloud").
    public var locationName: String {
        switch self {
        case .icloud:
            return "iCloud"
        case .local:
            return L10n.localDevice
        case .cloudKit:
            return "iCloud"
        }
    }

}
