//
//  MultiDeviceStateRecorder.swift
//  EncameraCore
//
//  Writes the always-synced multi-device state record (ENC-71 / ENC-81).
//

import Foundation

/// The only thing in the app that writes `MultiDeviceState`.
///
/// Two things go into the record: a roster entry naming this device so
/// destructive-path copy can say "10 images from your iPhone", and this
/// device's key fingerprints so the returning-user warning can name a key and
/// manually entered keys can be validated offline.
///
/// **The record is only ever written once the account demonstrably exists** —
/// from onboarding completion, or from a launch where the user has already
/// authenticated. Writing it during onboarding would be a real bug rather than
/// a cosmetic one: a genuinely new user who abandons setup would come back on
/// their next install and be shown returning-user warnings about an account
/// they never had.
///
/// Every write goes through `KeyManager.setMultiDeviceState`, which merges into
/// whatever is already stored. So this type only ever passes its *own*
/// contribution — one device record, its own fingerprints — and never has to
/// read-modify-write the roster.
///
/// The caller is responsible for not invoking this under UI test mode; see the
/// `UITestMode.recordsMultiDeviceState` gate at the call sites.
public struct MultiDeviceStateRecorder {

    private let keyManager: KeyManager
    private let deviceID: () -> String
    private let deviceName: () -> String
    private let now: () -> Date

    public init(
        keyManager: KeyManager,
        deviceID: @escaping () -> String = { DeviceIDProvider.deviceID() },
        deviceName: @escaping () -> String = { DeviceIDProvider.deviceName() },
        now: @escaping () -> Date = { Date() }
    ) {
        self.keyManager = keyManager
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.now = now
    }

    /// Called when onboarding completes — the point at which the user
    /// definitively has an account.
    public func recordOnboardingCompleted() {
        write(extraFingerprints: [])
    }

    /// Called on each launch once the user has authenticated. Refreshes this
    /// device's `lastSeen` in place rather than adding a duplicate entry —
    /// `deviceID` is stable for the install, and the merge dedupes on it.
    public func recordAuthenticatedLaunch() {
        write(extraFingerprints: [])
    }

    /// Called when a key is created or imported, so the fingerprint reaches
    /// other devices for the "your existing key is 54E0-7B52" warning and for
    /// offline validation of a manually entered key.
    ///
    /// Takes the key rather than reading `storedKeys()` so it works on the
    /// creation path before any published state has settled; the sweep below
    /// picks up anything this misses on the next launch.
    public func recordKeyCreated(_ key: PrivateKey) {
        write(extraFingerprints: [key.keychainLabel])
    }

    // MARK: - Private

    private func write(extraFingerprints: [String] = []) {
        let record = MultiDeviceState.DeviceRecord(
            deviceID: deviceID(),
            name: deviceName(),
            lastSeen: now()
        )

        var fingerprints = extraFingerprints
        // Fingerprints only; `keychainLabel` is a keyed BLAKE2b digest, never
        // the key bytes. See the security note on MultiDeviceState.
        for label in (try? keyManager.storedKeys())?.map(\.keychainLabel) ?? []
        where !fingerprints.contains(label) {
            fingerprints.append(label)
        }

        do {
            try keyManager.setMultiDeviceState(MultiDeviceState(
                devices: [record],
                keyFingerprints: fingerprints
            ))
        } catch {
            // Best-effort telemetry about the account, not a source of truth
            // for anything the user is doing right now. A failed write is
            // retried on the next launch.
            debugPrint("MultiDeviceStateRecorder: could not write multi-device state: \(error)")
        }
    }
}
