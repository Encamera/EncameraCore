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
    
    public static func isStorageTypeAvailable(type: StorageType) -> StorageType.Availability {
        switch type {
        case .icloud:
            guard !FeatureToggle.isEnabled(feature: .cloudKitStorage) else {
                return .unavailable(reason: "iCloud Drive storage is not enabled")
            }
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
    
    public static func storageAvailabilities() -> [StorageAvailabilityModel] {
        var availabilites = [StorageAvailabilityModel]()
        for type in StorageType.allCases {
            let result = isStorageTypeAvailable(type: type)
            availabilites += [StorageAvailabilityModel(storageType: type, availability: result)]
        }
        return availabilites
    }
}
