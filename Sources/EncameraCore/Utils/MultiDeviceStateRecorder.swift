//
//  MultiDeviceStateRecorder.swift
//  EncameraCore
//
//  Sweeps this device's keys into the always-synced multi-device state record
//  on each authenticated launch.
//

import Foundation

/// The launch-time writer of `MultiDeviceState`.
///
/// Two things go into the record: a roster entry naming this device, with a
/// fresh `lastSeen`, so destructive-path copy can say "10 images from your
/// iPhone"; and every stored key's fingerprint, with this device claimed as
/// the origin of the ones minted here (`MintedKeys`), so the returning-user
/// warning can name a key and manually entered keys can be validated offline.
///
/// A key this device mints or adds is published the moment it is written, by
/// `KeyMintingManager`. This sweep is the backstop: it picks up keys that
/// arrived from the account through iCloud Keychain or `KeychainSyncManager`,
/// and anything a failed publish left out.
///
/// Every write goes through `KeyManager.setMultiDeviceState`, which merges into
/// whatever is already stored, so this only ever passes its own contribution
/// and never has to read-modify-write the roster.
///
/// The caller is responsible for not invoking this under UI test mode; see the
/// `UITestMode.recordsMultiDeviceState` gate at the call site.
public struct MultiDeviceStateRecorder {

    private let keyManager: KeyManager
    private let deviceID: () -> String
    private let deviceName: () -> String
    private let now: () -> Date
    private let mintedFingerprints: () -> Set<String>

    public init(
        keyManager: KeyManager,
        deviceID: @escaping () -> String = { DeviceIDProvider.deviceID() },
        deviceName: @escaping () -> String = { DeviceIDProvider.deviceName() },
        now: @escaping () -> Date = { Date() },
        mintedFingerprints: @escaping () -> Set<String> = { MintedKeys.fingerprintsMintedOnThisDevice() }
    ) {
        self.keyManager = keyManager
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.now = now
        self.mintedFingerprints = mintedFingerprints
    }

    /// Called on each launch once the user has authenticated. Refreshes this
    /// device's `lastSeen` in place rather than adding a duplicate entry —
    /// `deviceID` is stable for the install, and the merge dedupes on it.
    public func recordAuthenticatedLaunch() {
        let record = MultiDeviceState.DeviceRecord(
            deviceID: deviceID(),
            name: deviceName(),
            lastSeen: now()
        )

        // Fingerprints only; `keyFingerprint` is a keyed BLAKE2b digest, never
        // the key bytes. See the security note on MultiDeviceState.
        let fingerprints = (try? keyManager.storedKeys())?.map(\.keyFingerprint) ?? []

        // Claims only the keys generated here; the merge keeps an earlier claim.
        let minted = mintedFingerprints()
        let origins = Dictionary(uniqueKeysWithValues: fingerprints
            .filter { minted.contains($0) }
            .map { ($0, record.deviceID) })

        do {
            try keyManager.setMultiDeviceState(MultiDeviceState(
                devices: [record],
                keyFingerprints: fingerprints,
                keyOrigins: origins
            ))
        } catch {
            debugPrint("MultiDeviceStateRecorder: could not write multi-device state: \(error)")
        }
    }
}
