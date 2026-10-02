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
    case noWayIn(BiometricAvailability)

    /// - Parameters:
    ///   - passcodeType: `.none` means this account has no pin or password at
    ///     all, so biometrics is not a shortcut — it is the only door.
    ///   - biometricsEnabled: the per-device consent. A device that synced a
    ///     biometrics-only account but never answered the prompt has usable
    ///     hardware it is not yet allowed to use.
    ///   - availability: the silent `canEvaluatePolicy` probe.
    public static func resolve(
        passcodeType: PasscodeType,
        biometricsEnabled: Bool,
        availability: BiometricAvailability
    ) -> LockScreenState {
        let usableBiometric = biometricsEnabled ? availability.method : nil

        guard passcodeType == .none else {
            return .passcode(passcodeType, biometric: usableBiometric)
        }
        guard let usableBiometric else {
            return .noWayIn(availability)
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
        /// The fix happens outside the app (enrol, set a device passcode,
        /// unlock the device); re-probe when the user comes back.
        case retry
    }

    public var recoveryAction: RecoveryAction? {
        guard case .noWayIn(let availability) = self else { return nil }
        switch availability {
        case .available(let method):
            return .enableOnThisDevice(method)
        case .deniedBySystemSettings:
            return .openSettings
        case .notEnrolled, .lockedOut, .passcodeNotSet, .noHardware, .unavailable:
            return .retry
        }
    }

    /// Whether turning biometrics on is something the user can actually do,
    /// so the screen can tell them it is the way in. A device without the
    /// hardware, or one failing for an unknown reason, has no such step.
    public var recoveryCanTurnOnBiometrics: Bool {
        guard case .noWayIn(let availability) = self else { return false }
        switch availability {
        case .available, .deniedBySystemSettings, .notEnrolled, .lockedOut, .passcodeNotSet:
            return true
        case .noHardware, .unavailable:
            return false
        }
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
