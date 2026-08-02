//
//  BiometricsDeviceConfirmation.swift
//  EncameraCore
//
//  `AuthenticationConfiguration` is written with a hardcoded
//  `kSecAttrSynchronizable: true`, so `.biometrics` inside it is an
//  ACCOUNT-WIDE flag, not a per-device one. Before this type existed,
//  `AuthManager.useBiometricsForAuth` read that flag directly: enabling Face ID
//  on an iPhone silently enabled it on a new iPad the moment the configuration
//  synced, without the user ever consenting on the iPad. Only the hardware
//  capability check (`LAContext.biometryType`) was per-device.
//
//  The model kept here: biometric unlock is DEVICE-LOCAL. It activates from
//  the hardware check plus this device's recorded consent, and turning it off
//  is likewise this device's business alone. The synced `.biometrics` flag is
//  written only when biometrics is the only way to auth into the app (no pin
//  on the account), so a fresh device knows there is no pin to ask for — it
//  never activates unlock by itself.
//

import Foundation

/// The three-way gate for biometric unlock, extracted so it can be tested
/// without an `LAContext` (whose biometry type is not injectable and differs
/// between simulators).
public enum BiometricUnlockDecision {
    public static func isActive(hasBiometricHardware: Bool,
                                confirmedOnThisDevice: Bool) -> Bool {
        // The synced flag plays no part here: with a pin on the account it is
        // never written at all, so activation is hardware plus local consent.
        hasBiometricHardware && confirmedOnThisDevice
    }
}

public enum BiometricsDeviceConfirmation {

    /// Whether the user has opted into biometric unlock on THIS device.
    /// `nil` means the question has never been answered here.
    public static var confirmation: Bool? {
        UserDefaultUtils.boolNullable(forKey: .biometricsConfirmedOnThisDevice)
    }

    public static var isConfirmed: Bool {
        confirmation == true
    }

    public static func setConfirmed(_ confirmed: Bool) {
        UserDefaultUtils.set(confirmed, forKey: .biometricsConfirmedOnThisDevice)
    }

    public static func clear() {
        UserDefaultUtils.removeObject(forKey: .biometricsConfirmedOnThisDevice)
        UserDefaultUtils.removeObject(forKey: .biometricsSeedWindowClosed)
    }

    /// One-time seed for devices that predate the per-device flag.
    ///
    /// An existing user who enabled Face ID before this shipped has the intent
    /// recorded only in the synced configuration; without a seed they would
    /// silently lose biometric unlock on upgrade. So on a device that has run
    /// the app before, adopt the configuration's value.
    ///
    /// A device that has NEVER run the app before is exactly the case this
    /// whole mechanism exists for — a fresh second device receiving someone
    /// else's intent — so it is deliberately left unanswered and must ask.
    /// That decline is sticky: the window closes on first evaluation whether or
    /// not it seeds, because `deviceHasLaunchedBefore` is re-derived from
    /// `.lastVersionKey` and reads true from launch 2 onward on every install.
    ///
    /// - Parameter deviceHasLaunchedBefore: whether this install has run a
    ///   previous session. Callers pass `UserDefaultUtils.string(forKey: .lastVersionKey) != nil`,
    ///   which is device-local and must be read before `LaunchCountUtils.recordCurrentVersionLaunch()`.
    public static func seedFromSyncedConfigurationIfNeeded(keyManager: KeyManager,
                                                          deviceHasLaunchedBefore: Bool) {
        guard confirmation == nil else { return }
        guard !UserDefaultUtils.bool(forKey: .biometricsSeedWindowClosed) else { return }
        UserDefaultUtils.set(true, forKey: .biometricsSeedWindowClosed)
        guard deviceHasLaunchedBefore else { return }
        setConfirmed(keyManager.getAuthenticationConfiguration()?.isTypeEnabled(.biometrics) ?? false)
    }
}
