import Foundation

/// What the lock screen can actually offer the user right now.
///
/// This exists because "offer nothing" used to be a reachable outcome. The
/// view composed its affordances independently — passcode input and the
/// instruction text behind `passwordExists()`, the biometric button behind a
/// non-nil `availableBiometric` — and a biometrics-only account fails both at
/// once whenever `canEvaluatePolicy` says no. Resolving the screen through a
/// single total function makes "nothing to show" unrepresentable.
public enum LockScreenState: Equatable {
    /// A passcode exists; show its input, with the biometric shortcut when
    /// biometrics can actually run.
    case passcode(PasscodeType, biometric: AuthenticationMethod?)
    /// No passcode on this account — biometrics is the only way in, and it works.
    case biometricOnly(AuthenticationMethod)
    /// No passcode, and biometrics cannot run. Nothing on the device can
    /// unlock the app until the user resolves the device-side condition, so
    /// the screen owes them the reason, a retry, and the erase escape hatch.
    /// `syncEnabled` is Multi-Device Mode: with it on, a passcode set on
    /// another device arrives through iCloud Keychain, so waiting is a way in.
    case noWayIn(BiometricAvailability, syncEnabled: Bool)

    /// - Parameters:
    ///   - passcodeType: `.none` means this account has no pin or password at
    ///     all, so biometrics is not a shortcut — it is the only door.
    ///   - biometricsEnabled: the per-device consent. A device that synced a
    ///     biometrics-only account but never answered the prompt has usable
    ///     hardware it is not yet allowed to use.
    ///   - availability: the silent `canEvaluatePolicy` probe.
    ///   - syncEnabled: whether credentials sync between this account's
    ///     devices, so one set elsewhere can still arrive here.
    public static func resolve(
        passcodeType: PasscodeType,
        biometricsEnabled: Bool,
        availability: BiometricAvailability,
        syncEnabled: Bool
    ) -> LockScreenState {
        let usableBiometric = biometricsEnabled ? availability.method : nil

        guard passcodeType == .none else {
            return .passcode(passcodeType, biometric: usableBiometric)
        }
        guard let usableBiometric else {
            return .noWayIn(availability, syncEnabled: syncEnabled)
        }
        return .biometricOnly(usableBiometric)
    }

    public var offersPasscodeEntry: Bool {
        if case .passcode = self { return true }
        return false
    }

    public var offersBiometricUnlock: Bool {
        switch self {
        case .biometricOnly:
            return true
        case .passcode(_, let biometric):
            return biometric != nil
        case .noWayIn:
            return false
        }
    }

    /// Whether the screen must show the reason, a retry, and the erase escape
    /// hatch. Only `.noWayIn` does: it is the one state where the user has no
    /// other move, and it is not reachable from the passcode lockout that
    /// normally surfaces the erase link.
    public var offersRecovery: Bool {
        if case .noWayIn = self { return true }
        return false
    }

    /// What the recovery screen offers as its way in.
    public enum RecoveryAction: Equatable {
        /// Biometrics works here but was never switched on for this device,
        /// as on a second device that synced a biometrics-only account. A
        /// successful prompt is the consent.
        case enableOnThisDevice(AuthenticationMethod)
        /// The app's Face ID permission is off; only Settings can undo it.
        case openSettings
        /// The fix happens outside the app (enrol a face or fingerprint, unlock
        /// the device); re-probe when the user comes back.
        case retry
        /// Nothing on this device can ever unlock the account and no passcode
        /// can sync in, so the reset is the only thing to offer.
        case resetOnly
        /// Multi-Device Mode is on, so a passcode set on the account's other
        /// device will sync here. Wait for it, re-reading the keychain, while
        /// still naming the device-side fix for this device's biometrics.
        case awaitPasscodeFromOtherDevice(BiometricAvailability)
    }

    /// Nil for a biometric lockout: it clears once the user unlocks the
    /// phone, so the lock screen shows it as an error with a retry instead of
    /// handing over to a recovery screen.
    public var recoveryAction: RecoveryAction? {
        guard case .noWayIn(let availability, let syncEnabled) = self else { return nil }
        switch availability {
        case .available(let method):
            // One tap is still the quickest way in, synced or not.
            return .enableOnThisDevice(method)
        case .lockedOut:
            return nil
        case _ where syncEnabled:
            return .awaitPasscodeFromOtherDevice(availability)
        case .deniedBySystemSettings:
            return .openSettings
        case .noHardware:
            return .resetOnly
        case .notEnrolled, .unavailable:
            return .retry
        }
    }

    /// A biometrics-only account whose biometry is locked out after too many
    /// failed attempts.
    public var biometricsLockedOut: Bool {
        if case .noWayIn(.lockedOut, _) = self { return true }
        return false
    }

    /// Whether the screen should keep re-reading the keychain for a passcode
    /// synced from another device.
    public var awaitsSyncedCredentials: Bool {
        if case .awaitPasscodeFromOtherDevice = recoveryAction { return true }
        return false
    }

    /// The biometry to offer, if any.
    public var biometric: AuthenticationMethod? {
        switch self {
        case .biometricOnly(let method):
            return method
        case .passcode(_, let biometric):
            return biometric
        case .noWayIn:
            return nil
        }
    }
}
