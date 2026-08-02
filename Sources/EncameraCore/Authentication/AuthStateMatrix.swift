//
//  AuthStateMatrix.swift
//  EncameraCore
//
//  The three pieces of credential state that decide what a launch can do are
//  stored in three keychain items with three different sync policies:
//
//  * `AuthenticationConfiguration` (`com.encamera.authenticationConfiguration`)
//    is written with a hardcoded `kSecAttrSynchronizable: true` — it ALWAYS
//    syncs, regardless of the iCloud key-backup toggle.
//  * the password hash (`encamera`) honours the toggle, so it syncs only when
//    key backup is on.
//  * the key items honour the toggle too.
//
//  Three independent presence bits with different sync policies means all
//  eight combinations are reachable in the field, including combinations that
//  no single device ever wrote. This file enumerates them and pins the
//  intended, non-lockout resolution for each. `Documentation/multi-device-state-matrix.md`
//  holds the human-readable version of the same table.
//

import Foundation

/// The `(auth config present?, password hash present?, key present?)` state
/// space and its intended resolutions.
public enum AuthStateMatrix {

    /// One of the eight reachable credential states.
    public struct Cell: Hashable, CustomStringConvertible {
        /// An `AuthenticationConfiguration` exists (always-synced item).
        public let configPresent: Bool
        /// A password hash exists on this device (sync follows the backup toggle).
        public let hashPresent: Bool
        /// At least one key item exists on this device.
        public let keyPresent: Bool

        public init(configPresent: Bool, hashPresent: Bool, keyPresent: Bool) {
            self.configPresent = configPresent
            self.hashPresent = hashPresent
            self.keyPresent = keyPresent
        }

        public var description: String {
            "config=\(configPresent) hash=\(hashPresent) key=\(keyPresent)"
        }
    }

    /// What a launch in a given cell must do.
    ///
    /// Every case is an escape: none of them leaves the user staring at a
    /// screen they cannot get past. `.lockedOut` exists only so the tests can
    /// assert that no cell maps to it — it is never returned.
    public enum Resolution: String, CaseIterable {
        /// Nothing has ever been set up here. Full onboarding.
        case onboarding
        /// This device holds key material but no password hash, so the normal
        /// unlock screen has nothing to verify against. Set a passcode WITHOUT
        /// regenerating or replacing the key.
        case passcodeSetup
        /// Normal unlock.
        case authenticate
        /// Normal unlock, plus rewrite the missing `AuthenticationConfiguration`
        /// from the passcode type that the password hash implies.
        case authenticateAndHealConfiguration
        /// The account existed but nothing usable landed here — typically the
        /// aftermath of key backup being switched off on another device, which
        /// tombstones the synced items everywhere. `KeyMissingView` explains it
        /// and offers key-phrase import or a fresh start.
        case keyMissing
        /// Not a resolution. Represents the pre-ENC-83 behaviour where a
        /// synced "a passcode is set" configuration met an absent hash and the
        /// user got an unlock screen no input could satisfy.
        case lockedOut
    }

    public static let allCells: [Cell] = [false, true].flatMap { config in
        [false, true].flatMap { hash in
            [false, true].map { key in
                Cell(configPresent: config, hashPresent: hash, keyPresent: key)
            }
        }
    }

    public static func resolution(for cell: Cell) -> Resolution {
        switch (cell.configPresent, cell.hashPresent, cell.keyPresent) {

        // Fresh install: nothing anywhere.
        case (false, false, false):
            return .onboarding

        // A key synced in before any authentication was configured — the
        // landing state of the "key arrives first" path. Setting up auth must
        // not run onboarding-from-scratch, which would treat the key as absent.
        case (false, false, true):
            return .passcodeSetup

        // Pre-configuration installs (the configuration item post-dates the
        // password hash). Authentication works; heal the configuration.
        case (false, true, false), (false, true, true):
            return .authenticateAndHealConfiguration

        // Only the always-synced configuration made it here. There is no key to
        // protect and no hash to check, so this is a recovery screen, not a
        // lockout — and specifically not a silent onboarding, because the user
        // does have an account whose key may be recoverable from a key phrase.
        case (true, false, false):
            return .keyMissing

        // THE LOCKOUT. The configuration says "a passcode is set" but the hash
        // that would verify it never synced (backup off on the writing device),
        // while the key did arrive. The user owns data and cannot open it.
        // Passcode re-setup is the escape, and it must leave the key untouched.
        case (true, false, true):
            return .passcodeSetup

        // Configured and authenticatable. A missing key is handled after
        // unlock by the restore/heal hook, not by blocking the launch.
        case (true, true, false), (true, true, true):
            return .authenticate
        }
    }
}

public extension KeyManager {

    /// This device's current position in the auth-state matrix, or nil when
    /// the keychain cannot currently be read.
    ///
    /// nil is a fault, not a cell. Every credential item is stored
    /// `kSecAttrAccessibleWhenUnlocked`, so a read before first unlock (or from
    /// a process missing the keychain entitlement) fails wholesale with e.g.
    /// `errSecInteractionNotAllowed` — a state indistinguishable from a fresh
    /// install if it collapses into "absent". It must never be routed as one:
    /// `.onboarding` and `.passcodeSetup` are destructive if reached through a
    /// fault. `storedKeys()` is the one presence read that surfaces its
    /// OSStatus, and the fault states that make presence unknowable fail every
    /// query in the process, so it doubles as the canary for all three bits.
    ///
    /// "Key present" counts any stored key, not just the default one: a user
    /// who imported a key phrase under a different name still owns data.
    func authStateCell() -> AuthStateMatrix.Cell? {
        let keys: [PrivateKey]
        do {
            keys = try storedKeys()
        } catch {
            return nil
        }
        return AuthStateMatrix.Cell(
            configPresent: getAuthenticationConfiguration() != nil,
            hashPresent: passwordExists(),
            keyPresent: !keys.isEmpty
        )
    }

    /// True when this device holds key material it cannot unlock, because no
    /// password hash is present to verify a passcode against. False on a read
    /// fault: passcode setup must never be triggered by an unreadable keychain.
    var needsPasscodeSetup: Bool {
        guard let cell = authStateCell() else { return false }
        return AuthStateMatrix.resolution(for: cell) == .passcodeSetup
    }
}
