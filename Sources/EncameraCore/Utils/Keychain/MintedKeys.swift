//
//  MintedKeys.swift
//  EncameraCore
//

import Foundation

/// The keys generated on this device, kept device-local. Recorded at
/// generation, which can precede the account existing, and published to the
/// synced `MultiDeviceState.keyOrigins` by `MultiDeviceStateRecorder`.
public enum MintedKeys {

    public static func record(_ key: PrivateKey) {
        var fingerprints = fingerprintsMintedOnThisDevice()
        guard fingerprints.insert(key.keyFingerprint).inserted else { return }
        UserDefaultUtils.set(Array(fingerprints).sorted(), forKey: .keysMintedOnThisDevice)
    }

    public static func fingerprintsMintedOnThisDevice() -> Set<String> {
        Set(UserDefaultUtils.value(forKey: .keysMintedOnThisDevice) as? [String] ?? [])
    }
}
