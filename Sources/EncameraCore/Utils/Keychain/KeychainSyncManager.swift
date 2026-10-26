//
//  KeychainSyncManager.swift
//  EncameraCore
//
//  Created by Alexander Freas on 13.10.26.
//

import Foundation

/// What one `KeychainSyncManager.syncKeychainItems()` call did.
public enum KeychainSyncPassOutcome: Equatable {
    /// Nothing to do: the backup flag is absent, says backup is off, or has
    /// not changed since the last pass that completed cleanly.
    case skipped(KeychainSyncSkipReason)
    /// The adoption pass ran; `failures` lists each item that could not be
    /// adopted, empty when every item is now in the account's state.
    case ran(failures: [String])
}

public enum KeychainSyncSkipReason: Equatable {
    case flagNotSet
    case backupDisabled
    case unchanged
}

/// Brings this device's credentials in line with the account's after another
/// device turned iCloud Backup & Sync on.
///
/// The Settings toggle only flips the items on the device it is tapped on. On
/// every other device the flag arrives, `isSyncEnabled` starts answering
/// `true`, and new writes follow it — but the keys, passphrases, password hash
/// and authentication configuration that already existed there stay local and
/// never reach the account. This actor is the passive counterpart: it watches the
/// always-synced backup flag and, when it changes to enabled, adopts the
/// account's copy of every credential. A synced copy wins and the local copy
/// is deleted; a local-only item is moved up so the other devices receive it.
/// Nothing is ever written to the synced scope from an item that already has
/// a synced copy, so this device's stale credentials never propagate.
///
/// Only the enabled direction is handled. When backup is turned off
/// elsewhere, that device's deletions of the synced copies propagate on their
/// own, and whether they or the flag arrive first is not knowable here.
public actor KeychainSyncManager: DebugPrintable {

    private let privateKeyManager: PrivateKeyManager
    private let passwordManager: KeychainPasswordManager
    private let backupStatusManager: KeychainBackupStatusManager

    /// The flag value the last clean pass acted on. Compared whole, not just on
    /// `enabled`, so a second enable from another device after a disable is
    /// seen as a change. Left unset after a pass with failures so the next tick
    /// retries; the adoption is idempotent.
    private var lastSeenStatus: KeychainBackupStatus?
    private var monitorTask: Task<Void, Never>?

    init(privateKeyManager: PrivateKeyManager,
         passwordManager: KeychainPasswordManager,
         backupStatusManager: KeychainBackupStatusManager) {
        self.privateKeyManager = privateKeyManager
        self.passwordManager = passwordManager
        self.backupStatusManager = backupStatusManager
    }

    /// Reads the backup flag and, if it changed to enabled, runs the adoption
    /// pass. Then, when no key is current, selects one of the keys that have
    /// arrived: that runs on every pass, because key items usually arrive after
    /// the flag. Cheap when nothing changed: a few keychain reads.
    @discardableResult
    public func syncKeychainItems() -> KeychainSyncPassOutcome {
        let outcome = adoptAccountCredentialsIfFlagChanged()
        if privateKeyManager.currentKey == nil,
           let key = privateKeyManager.selectActiveKeyIfNeeded() {
            printDebug("selected arrived key \(key.keyFingerprint) as the current key")
        }
        return outcome
    }

    private func adoptAccountCredentialsIfFlagChanged() -> KeychainSyncPassOutcome {
        guard let status = backupStatusManager.getBackupStatus() else {
            lastSeenStatus = nil
            return .skipped(.flagNotSet)
        }
        guard status != lastSeenStatus else {
            return .skipped(.unchanged)
        }
        guard status.enabled else {
            lastSeenStatus = status
            printDebug("backup flag is off; nothing to adopt")
            return .skipped(.backupDisabled)
        }

        printDebug("backup flag changed to on (by \(status.deviceName ?? "unknown device")); adopting the account's credentials")
        let failures = privateKeyManager.adoptSyncedKeys() + passwordManager.adoptSyncedPassword()
        if failures.isEmpty {
            lastSeenStatus = status
        } else {
            printDebug("adoption FAILURES, will retry on the next pass: \(failures.joined(separator: "; "))")
        }
        return .ran(failures: failures)
    }

    /// Polls the backup flag every `interval` seconds for as long as the app
    /// runs. The keychain has no change notification, and the flag typically
    /// lands minutes after launch on the device that matters, so a launch-time
    /// check alone would require a relaunch.
    public func startMonitoring(interval: TimeInterval = 60) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncKeychainItems()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }
}
