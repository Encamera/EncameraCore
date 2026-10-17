//
//  File.swift
//  EncameraCore
//
//  Created by Alexander Freas on 14.10.26.
//

import Foundation
import Security

final class KeychainMigrationManager: DebugPrintable {

    private let keychainWrapper: KeychainWrapperProtocol
    private let privateKeyManager: PrivateKeyManager

    init(keychainWrapper: KeychainWrapperProtocol, privateKeyManager: PrivateKeyManager) {
        self.keychainWrapper = keychainWrapper
        self.privateKeyManager = privateKeyManager
    }

    /// Moves every passphrase stored under the single legacy account
    /// `KeychainConstants.passPhraseKeyItem` onto the item for the fingerprint
    /// of the key it derives.
    ///
    /// Each copy is relabelled in place, in its own sync scope, with
    /// `SecItemUpdate` and never `SecItemDelete`: deleting a synchronizable
    /// item tombstones it account-wide. A copy whose fingerprinted item already
    /// exists in the same scope is left where it is. Idempotent.
    @discardableResult
    func migrateLegacyPassphraseToFingerprintedPassphrase() throws -> KeychainMigrationStepResult {
        let items = try fetchLegacyPassphraseItems()

        var result = KeychainMigrationStepResult()
        for keychainItem in items {
            let isSynced = (keychainItem[kSecAttrSynchronizable as String] as? Bool) ?? false
            guard let fingerprint = keyFingerprint(forLegacyPassphraseItem: keychainItem) else {
                result.skipped += 1
                printDebug("migrateLegacyPassphrase: skipping undecodable item (synced=\(isSynced))")
                continue
            }
            let status = relabelLegacyPassphrase(toFingerprint: fingerprint, isSynced: isSynced)
            recordPassphraseRelabel(status: status, fingerprint: fingerprint, isSynced: isSynced, into: &result)
        }
        printDebug("migrateLegacyPassphrase: moved \(result.migrated) of \(items.count) legacy items")
        return result
    }

    /// Every copy of the legacy passphrase item, local and synced alike.
    /// Empty when none exists.
    private func fetchLegacyPassphraseItems() throws -> [[String: Any]] {
        try allItems(matching: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passPhraseKeyItem
        ])
    }

    /// The fingerprint of the key a legacy item's passphrase derives, or nil
    /// when the item does not decode to a passphrase that yields a key.
    private func keyFingerprint(forLegacyPassphraseItem item: [String: Any]) -> String? {
        guard let passphrase = KeyPassphrase(keychainValue: item),
              let key = try? PrivateKey(passphrase: passphrase) else {
            return nil
        }
        return key.keyFingerprint
    }

    /// Rewrites the legacy item in one sync scope onto the fingerprinted
    /// account in place, and reports the keychain's status.
    private func relabelLegacyPassphrase(toFingerprint fingerprint: String, isSynced: Bool) -> OSStatus {
        let targetQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passPhraseKeyItem,
            kSecAttrSynchronizable as String: isSynced ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
        var attributes = privateKeyManager.queryForPassphrase(fingerprint: fingerprint)
        attributes.removeValue(forKey: kSecClass as String)
        return keychainWrapper.secItemUpdate(targetQuery as CFDictionary, attributes as CFDictionary)
    }

    /// Counts one relabel's outcome. A duplicate means the fingerprinted item
    /// already exists in that scope, so the legacy copy is left where it is
    /// and counts as neither migrated nor failed.
    private func recordPassphraseRelabel(status: OSStatus,
                                         fingerprint: String,
                                         isSynced: Bool,
                                         into result: inout KeychainMigrationStepResult) {
        switch status {
        case errSecSuccess:
            result.migrated += 1
            printDebug("migrateLegacyPassphrase: moved to \(fingerprint) (synced=\(isSynced))")
        case errSecDuplicateItem:
            printDebug("migrateLegacyPassphrase: \(fingerprint) already stored (synced=\(isSynced)), leaving legacy copy")
        default:
            result.recordFailedWrite(status: status)
            printDebug("migrateLegacyPassphrase: FAILED for \(fingerprint) (synced=\(isSynced)) — status \(status) (\(determineOSStatus(status: status)))")
        }
    }

    /// Runs the keychain migrations a 2.x install needs to read as 3.x: keys
    /// relabelled to their fingerprints, then passphrases moved onto their
    /// key's fingerprint. Both are idempotent, so this runs on every launch and
    /// retries anything a previous launch could not finish. A step that cannot
    /// run does not stop the next.
    func migrateFromV2ToV3IfNeeded() -> KeychainMigrationReport {
        var report = KeychainMigrationReport()
        report.keyLabels = runStep("key label migration") { try migrateKeyLabelsToFingerprintsIfNeeded() }
        report.passphrases = runStep("passphrase migration") { try migrateLegacyPassphraseToFingerprintedPassphrase() }
        return report
    }

    private func runStep(_ name: String,
                         _ step: () throws -> KeychainMigrationStepResult) -> KeychainMigrationReport.Outcome {
        do {
            return .ran(try step())
        } catch {
            printDebug("migrateFromV2ToV3: \(name) FAILED:", error)
            return .couldNotRun(reason: KeychainMigrationReport.reason(for: error))
        }
    }

    /// Relabels name-addressed key items to fingerprint-addressed ones, in
    /// place. Idempotent — items already carrying a fingerprint label are left
    /// untouched, so it is safe to run on every launch.
    ///
    /// Uses `SecItemUpdate` exclusively and never `SecItemDelete`: deleting a
    /// synchronizable item tombstones it account-wide and the deletion
    /// propagates to every other device. Each item is targeted in its
    /// own sync scope so a local and a synced copy of the same key are
    /// relabelled independently rather than one clobbering the other.
    func migrateKeyLabelsToFingerprintsIfNeeded() throws -> KeychainMigrationStepResult {
        let items = try fetchKeyItems()

        var result = KeychainMigrationStepResult()
        for keychainItem in items {
            guard let label = nameLabel(ofKeyItem: keychainItem) else { continue }
            guard let key = try? PrivateKey(keychainItem: keychainItem) else {
                result.skipped += 1
                printDebug("migrateKeyLabels: skipping undecodable item labelled \(label.name)")
                continue
            }
            let isSynced = (keychainItem[kSecAttrSynchronizable as String] as? Bool) ?? false
            let status = relabelKey(key, labelled: label.data, isSynced: isSynced)
            recordKeyRelabel(status: status, from: label.name, to: key.keyFingerprint, isSynced: isSynced, into: &result)
        }
        if result.migrated > 0 {
            repinActiveKeyPointerIfNamed()
        }
        printDebug("migrateKeyLabels: relabelled \(result.migrated) of \(items.count) key items")
        return result
    }

    /// Every key item, local and synced alike. Empty when none exists.
    private func fetchKeyItems() throws -> [[String: Any]] {
        try allItems(matching: [kSecClass as String: kSecClassKey])
    }

    /// The display name a key item still carries as its label, with the raw
    /// label bytes that address it. Nil when the item already carries a
    /// fingerprint label or its label is unreadable; neither needs migrating.
    private func nameLabel(ofKeyItem item: [String: Any]) -> (data: Data, name: String)? {
        guard let data = item[kSecAttrLabel as String] as? Data,
              let name = String(data: data, encoding: .utf8),
              !PrivateKey.isFingerprintLabel(name) else {
            return nil
        }
        return (data, name)
    }

    /// Rewrites the key item addressed by `labelData` in one sync scope onto
    /// its fingerprint identity in place, and reports the keychain's status.
    private func relabelKey(_ key: PrivateKey, labelled labelData: Data, isSynced: Bool) -> OSStatus {
        let targetQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: labelData,
            kSecAttrSynchronizable as String: isSynced ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
        return keychainWrapper.secItemUpdate(targetQuery as CFDictionary,
                                             key.keychainIdentityAttributes as CFDictionary)
    }

    /// Counts one relabel's outcome.
    private func recordKeyRelabel(status: OSStatus,
                                  from existingLabel: String,
                                  to fingerprint: String,
                                  isSynced: Bool,
                                  into result: inout KeychainMigrationStepResult) {
        if status == errSecSuccess {
            result.migrated += 1
            printDebug("migrateKeyLabels: relabelled \(existingLabel) -> \(fingerprint) (synced=\(isSynced))")
        } else {
            result.recordFailedWrite(status: status)
            printDebug("migrateKeyLabels: FAILED to relabel \(existingLabel) — status \(status) (\(determineOSStatus(status: status)))")
        }
    }

    /// Re-pins a name-based current-key pointer onto a fingerprint. Guarded
    /// on a pointer already being set: migration must never choose a current
    /// key when there is none.
    private func repinActiveKeyPointerIfNamed() {
        guard let pointer = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String,
              !PrivateKey.isFingerprintLabel(pointer) else {
            return
        }
        _ = try? privateKeyManager.getActiveKey()
    }

    /// Every item matching `query` with its data and attributes, across both
    /// sync scopes. Empty when none exists; throws for any other read failure.
    private func allItems(matching query: [String: Any]) throws -> [[String: Any]] {
        var fullQuery = query
        fullQuery[kSecReturnData as String] = true
        fullQuery[kSecReturnAttributes as String] = true
        fullQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        fullQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(fullQuery as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        try KeychainManager.checkStatus(status: status)
        return item as? [[String: Any]] ?? []
    }
}

/// What one migration step did on one launch.
public struct KeychainMigrationStepResult: Equatable {
    public internal(set) var migrated = 0
    /// Items that could not be decoded and were left where they are.
    public internal(set) var skipped = 0
    /// Items whose rewrite the keychain refused, counted by status name.
    public internal(set) var failedWrites: [String: Int] = [:]

    public init(migrated: Int = 0, skipped: Int = 0, failedWrites: [String: Int] = [:]) {
        self.migrated = migrated
        self.skipped = skipped
        self.failedWrites = failedWrites
    }

    mutating func recordFailedWrite(status: OSStatus) {
        failedWrites[determineOSStatus(status: status), default: 0] += 1
    }
}

/// What `migrateFromV2ToV3IfNeeded()` did on one launch, per step.
public struct KeychainMigrationReport {
    public enum Outcome: Equatable {
        case ran(KeychainMigrationStepResult)
        /// The step could not read the keychain. `reason` is the keychain
        /// status name or the error type, never item contents.
        case couldNotRun(reason: String)
    }

    public internal(set) var keyLabels: Outcome = .ran(KeychainMigrationStepResult())
    public internal(set) var passphrases: Outcome = .ran(KeychainMigrationStepResult())

    public init(keyLabels: Outcome = .ran(KeychainMigrationStepResult()),
                passphrases: Outcome = .ran(KeychainMigrationStepResult())) {
        self.keyLabels = keyLabels
        self.passphrases = passphrases
    }

    static func reason(for error: Error) -> String {
        if case KeyManagerError.unhandledError(let statusName) = error {
            return statusName
        }
        return String(describing: error)
    }
}
