//
//  DeviceIdentity.swift
//  EncameraCore
//
//  A stable per-install identifier written to a CloudKit record's
//  `creationDeviceID`, so a device can later tell "I authored this" (keep local)
//  vs "fetch on tap" (the chunk-03 eviction policy). Stored in app-group defaults.
//

import Foundation

public enum DeviceIdentity {
    private static let key = "cloudkit_device_id_v1"

    /// The current install's device id, generated and persisted on first access.
    public static var current: String {
        currentID(defaults: UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard)
    }

    /// Testable variant: resolve (and lazily create) the id in an explicit store.
    static func currentID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }
}
