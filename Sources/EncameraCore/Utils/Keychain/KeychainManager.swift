//
//  KeychainManager.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
import Sodium
import Combine
import Security
import UIKit

public class KeychainManager: ObservableObject, @preconcurrency KeyManager, DebugPrintable {

    /// Which credential set this device uses when a local (this device) and a
    /// synced (another device) copy of the same item coexist with different
    /// values — the aftermath of onboarding on a second device before iCloud
    /// Keychain delivered the first device's credentials.
    public enum CredentialConflictResolution: String {
        case preferLocal
        case preferSynced

        /// The resolution this device has chosen, or nil when none is set.
        static var stored: CredentialConflictResolution? {
            guard let raw = UserDefaultUtils.string(forKey: .credentialConflictResolution) else {
                return nil
            }
            return CredentialConflictResolution(rawValue: raw)
        }
    }

    // MARK: - Public Properties

    public var isAuthenticated: AnyPublisher<Bool, Never>

    public var currentKey: PrivateKey? {
        privateKeyManager.currentKey
    }

    public var keyPublisher: AnyPublisher<PrivateKey?, Never> {
        privateKeyManager.keyPublisher
    }

    public var passcodeType: PasscodeType {
        passwordManager.passcodeType
    }

    public var backupFlagState: KeychainBackupFlagState {
        backupStatusManager.getBackupFlagState()
    }

    /// Full payload of the backup status item, including which device flipped
    /// the switch and when. Nil when the item is absent or undecodable;
    /// metadata fields are nil for legacy boolean payloads.
    public var backupStatus: KeychainBackupStatus? {
        backupStatusManager.getBackupStatus()
    }

    public var conflictResolution: CredentialConflictResolution? {
        CredentialConflictResolution.stored
    }

    public var isSyncEnabled: Bool {
        switch backupStatusManager.getBackupFlagState() {
        case .enabled: return true
        case .disabled: return false
        case .notSet:
            if let observed = privateKeyManager.observedKeySyncState() {
                printDebug("isSyncEnabled: flag notSet, key library observed sync state → \(observed)")
                return observed
            }

            // The backup-flag account itself is excluded: that item is always
            // written synchronizable and would make this check unconditionally true.
            let credentialAccounts = [
                KeychainConstants.account,
                KeychainConstants.passPhraseKeyItem,
                KeychainConstants.passcodeTypeKeyItem
            ]
            if let matched = credentialAccounts.first(where: { genericPasswordData(account: $0, synchronizable: true) != nil }) {
                printDebug("isSyncEnabled: flag notSet, but synchronizable '\(matched)' item exists → true")
                return true
            }
            printDebug("isSyncEnabled: flag notSet and no synchronizable credential items → false (writes will be local-only)")
            return false
        }
    }

    // MARK: - Internal Properties

    let keychainWrapper: KeychainWrapperProtocol

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private let multiDeviceManager: MultiDeviceManager
    private let privateKeyManager: PrivateKeyManager
    private let passwordManager: KeychainPasswordManager
    private let eraseManager: KeychainEraseManager
    private let backupStatusManager: KeychainBackupStatusManager
    private var passwordValidator = PasswordValidator()
    private var didLogVariantDetail = false

    // MARK: - Init

    public required init(isAuthenticated: AnyPublisher<Bool, Never>, keychainWrapper: KeychainWrapperProtocol = KeychainWrapper()) {
        self.isAuthenticated = isAuthenticated
        self.keychainWrapper = keychainWrapper
        self.multiDeviceManager = MultiDeviceManager(keychainWrapper: keychainWrapper)
        self.privateKeyManager = PrivateKeyManager(keychainWrapper: keychainWrapper)
        self.passwordManager = KeychainPasswordManager(keychainWrapper: keychainWrapper)
        self.backupStatusManager = KeychainBackupStatusManager(keychainWrapper: keychainWrapper)
        self.eraseManager = KeychainEraseManager(keychainWrapper: keychainWrapper,
                                                 privateKeyManager: privateKeyManager,
                                                 multiDeviceManager: multiDeviceManager,
                                                 passwordManager: passwordManager)
        self.isAuthenticated.sink { [weak self] newValue in
            guard let self = self, newValue == true else { return }
            do {
                try self.privateKeyManager.getActiveKeyAndSet()
            } catch {
                self.printDebug("Error during initial key setup (migration/load):", error)
                self.attemptKeyRestoreAfterFailedLoad()
            }
        }.store(in: &cancellables)
    }

    // MARK: - Credential State

    public func credentialSnapshot() -> KeychainCredentialSnapshot {
        if !didLogVariantDetail {
            didLogVariantDetail = true
            logCredentialVariantState(context: "first credentialSnapshot")
        }
        let configuration = getAuthenticationConfiguration()
        let status = backupStatusManager.getBackupStatus()
        let flagState: KeychainBackupFlagState = status.map { $0.enabled ? .enabled : .disabled } ?? .notSet
        let snapshot = KeychainCredentialSnapshot(
            passwordExists: passwordExists(),
            passphraseExists: keyPassphraseExists(),
            defaultKeyExists: !((try? storedKeys()) ?? []).isEmpty,
            biometricsEnabled: configuration?.isTypeEnabled(.biometrics) ?? false,
            backupFlagState: flagState,
            backupStatus: status
        )
        printDebug("credentialSnapshot: \(snapshot)")
        return snapshot
    }

    /// Logs, for every credential account and key, whether a local and/or a
    /// synced variant exists. This is the view that distinguishes "item never
    /// marked synchronizable on the source device" from "item hasn't arrived
    /// here yet" — run it on BOTH devices when diagnosing sync.
    public func logCredentialVariantState(context: String) {
        let accounts = [
            KeychainConstants.account,
            KeychainConstants.passPhraseKeyItem,
            KeychainConstants.passcodeTypeKeyItem,
            KeychainConstants.backupStatusKeyItem
        ]
        for account in accounts {
            let local = genericPasswordData(account: account, synchronizable: false) != nil
            let synced = genericPasswordData(account: account, synchronizable: true) != nil
            printDebug("variant state (\(context)) '\(account)': local=\(local), synced=\(synced)")
        }
        let keys = (try? storedKeys()) ?? []
        if keys.isEmpty {
            printDebug("variant state (\(context)) keys: none")
        } else {
            let describedKeys = keys.map { "\($0.keychainLabel)(synced=\($0.savedToiCloud))" }.joined(separator: ", ")
            printDebug("variant state (\(context)) keys: \(describedKeys)")
        }
    }

    public func hasResolvedCredentialsBefore() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.credentialResolutionMarker,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        return keychainWrapper.secItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func setResolvedCredentialsBefore() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.credentialResolutionMarker,
            kSecAttrSynchronizable as String: kCFBooleanFalse!
        ]
        guard keychainWrapper.secItemCopyMatching(query as CFDictionary, nil) != errSecSuccess else { return true }
        var add = query
        add[kSecValueData as String] = Data([1])
        return keychainWrapper.secItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Credential Conflicts

    public func setConflictResolution(_ resolution: CredentialConflictResolution?) {
        printDebug("setConflictResolution(\(resolution?.rawValue ?? "nil")) — was \(conflictResolution?.rawValue ?? "nil")")
        if let resolution {
            UserDefaultUtils.set(resolution.rawValue, forKey: .credentialConflictResolution)
        } else {
            UserDefaultUtils.removeObject(forKey: .credentialConflictResolution)
        }
    }

    /// Reported by `detectCredentialConflicts()` when the stored keys disagree.
    public static let keyConflictIdentifier = "key"

    /// Returns the accounts (or `keyConflictIdentifier`) whose local and synced
    /// keychain items coexist with differing values. Empty when there is no
    /// conflict. Never deletes or modifies anything.
    public func detectCredentialConflicts() -> [String] {
        var conflicts: [String] = []

        let accounts = [
            KeychainConstants.account,
            KeychainConstants.passPhraseKeyItem,
            KeychainConstants.passcodeTypeKeyItem
        ]
        for account in accounts {
            let local = genericPasswordData(account: account, synchronizable: false)
            let synced = genericPasswordData(account: account, synchronizable: true)
            printDebug("conflict check '\(account)': local=\(local != nil ? "\(local!.count) bytes" : "absent"), synced=\(synced != nil ? "\(synced!.count) bytes" : "absent"), equal=\(local == synced)")
            if let local, let synced, local != synced {
                conflicts.append(account)
            }
        }

        let keyVariants = (try? storedKeys()) ?? []
        let distinctKeyBytes = Set(keyVariants.map { $0.keyBytes }).count
        printDebug("conflict check keys: \(keyVariants.count) variant(s), \(distinctKeyBytes) distinct keyBytes")
        if keyVariants.count > 1, distinctKeyBytes > 1 {
            conflicts.append(Self.keyConflictIdentifier)
        }

        printDebug("detectCredentialConflicts result: \(conflicts.isEmpty ? "none" : conflicts.joined(separator: ", "))")
        return conflicts
    }

    // MARK: - Erase

    public func clearKeychainData(scope: KeyDeletionScope) {
        eraseManager.clearKeychainData(scope: scope)
    }

    public func residualKeychainItemNames() -> [String] {
        eraseManager.residualKeychainItemNames()
    }

    // MARK: - Keys

    @discardableResult public func generateKeyUsingRandomWords() throws -> PrivateKey {
        try privateKeyManager.generateKeyUsingRandomWords(synchronizable: synchronizableForWrites)
    }

    @discardableResult public func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey {
        try privateKeyManager.saveKeyWithPassphrase(passphrase: passphrase, synchronizable: synchronizableForWrites)
    }

    public func deriveKey(from components: [String]) throws -> PrivateKey {
        try privateKeyManager.deriveKey(from: components)
    }

    /// Re-derives the default key from an already-present passphrase item.
    /// Exists for the second-device case where iCloud Keychain has delivered the
    /// password/passphrase items but the key item hasn't arrived (or was written
    /// non-synchronizable on the old device). Never writes the passphrase item,
    /// so a synced passphrase can't be overwritten or flipped local-only here.
    @discardableResult public func restoreDefaultKeyFromPassphraseIfNeeded() throws -> Bool {
        guard passwordExists() else {
            printDebug("restore: skipping — no password hash present")
            return false
        }
        guard ((try? storedKeys()) ?? []).isEmpty else {
            printDebug("restore: skipping — a key is already present")
            return false
        }
        guard let passphrase = try? retrieveKeyPassphrase() else {
            printDebug("restore: skipping — passphrase item not retrievable")
            return false
        }

        printDebug("restore: password present, default key absent, passphrase has \(passphrase.words.count) words — deriving key")
        let key = try deriveKey(from: passphrase.words)
        try save(key: key, setNewKeyToCurrent: true)
        printDebug("restore: default key re-derived and saved as current (isSyncEnabled=\(isSyncEnabled))")
        return true
    }

    @discardableResult public func generateKeyFromPasswordComponentsAndSave(_ components: [String]) throws -> PrivateKey {
        try privateKeyManager.generateKeyFromPasswordComponentsAndSave(components, synchronizable: synchronizableForWrites)
    }

    public func retrieveKeyPassphrase() throws -> KeyPassphrase {
        try privateKeyManager.retrieveKeyPassphrase(conflictResolution: conflictResolution)
    }

    public func save(key: PrivateKey, setNewKeyToCurrent: Bool) throws {
        try privateKeyManager.save(key: key, setNewKeyToCurrent: setNewKeyToCurrent, synchronizable: synchronizableForWrites)
    }

    public func update(key: PrivateKey, backupToiCloud: Bool) throws {
        try privateKeyManager.setSynchronizable(backupToiCloud, for: key)
    }

    public func keyWith(fingerprint: String) -> PrivateKey? {
        privateKeyManager.keyWith(fingerprint: fingerprint)
    }

    @MainActor
    public func keyWith(uuid: UUID) -> PrivateKey? {
        privateKeyManager.keyWith(uuid: uuid)
    }

    public func deleteKey(fingerprint: String, scope: KeyDeletionScope = .deviceLocal) throws {
        try privateKeyManager.deleteKey(fingerprint: fingerprint, scope: scope)
    }

    public func storedKeys() throws -> [PrivateKey] {
        try privateKeyManager.storedKeys()
    }

    public func clearActiveKey() {
        privateKeyManager.clearActiveKey()
    }

    public func setActiveKey(_ key: PrivateKey) throws {
        try privateKeyManager.setActiveKey(key)
    }

    func getActiveKey() throws -> PrivateKey {
        try privateKeyManager.getActiveKey()
    }

    public func keyPassphraseExists() -> Bool {
        privateKeyManager.keyPassphraseExists()
    }

    // MARK: - Password and Authentication

    public func getAuthenticationConfiguration() -> AuthenticationConfiguration? {
        passwordManager.getAuthenticationConfiguration()
    }

    public func setAuthenticationConfiguration(config: AuthenticationConfiguration) throws {
        try passwordManager.setAuthenticationConfiguration(config: config)
    }

    public func passwordExists() -> Bool {
        passwordManager.passwordExists()
    }

    public func clearPassword() throws {
        try passwordManager.clearPassword()
    }

    public func setPassword(_ password: String, type: PasscodeType) throws {
        try passwordManager.setPassword(password, type: type, synchronizable: synchronizableForWrites)
    }

    public func setOrUpdatePassword(_ password: String, type: PasscodeType) throws {
        try passwordManager.setOrUpdatePassword(password, type: type, synchronizable: synchronizableForWrites)
    }

    public func changePassword(newPassword: String, existingPassword: String, type: PasscodeType) throws {
        try passwordManager.changePassword(newPassword: newPassword, existingPassword: existingPassword, type: type, synchronizable: synchronizableForWrites)
    }

    public func getPasswordHash() throws -> Data {
        try passwordManager.getPasswordHash()
    }

    public func setPasswordHash(hash: Data) throws {
        try passwordManager.setPasswordHash(hash: hash, synchronizable: synchronizableForWrites)
    }

    public func checkPassword(_ password: String) throws -> Bool {
        try passwordManager.checkPassword(password)
    }

    // MARK: - Multi-Device

    public func getMultiDeviceState() -> MultiDeviceState? {
        multiDeviceManager.getState()
    }

    public func setMultiDeviceState(_ state: MultiDeviceState) throws {
        try multiDeviceManager.setState(state)
    }

    public func overwriteMultiDeviceState(_ state: MultiDeviceState) throws {
        try multiDeviceManager.overwriteState(state)
    }

    /// See `KeyManager.multiDeviceKeyConflict`.
    public func multiDeviceKeyConflict() -> MultiDeviceKeyConflict? {
        let localFingerprints = Set(((try? storedKeys()) ?? []).map(\.keychainLabel))
        let accountFingerprints = getMultiDeviceState()?.keyFingerprints ?? []
        let remoteOnly = accountFingerprints.filter { !localFingerprints.contains($0) }
        guard !remoteOnly.isEmpty else {
            return nil
        }
        return MultiDeviceKeyConflict(
            localFingerprint: (try? getActiveKey())?.keychainLabel,
            remoteFingerprints: remoteOnly
        )
    }

    // MARK: - iCloud Sync

    /// Moves every secret the app owns on or off the iCloud keychain, then
    /// records the new state in the central backup flag.
    ///
    /// Items first, flag last, and deliberately so: the flag is what
    /// `isSyncEnabled` — and therefore the Settings toggle — reads, so writing
    /// it before the items can leave the app reporting "backup off" over
    /// secrets that are still syncing.
    ///
    /// Each item is flipped independently and failures are collected, so a
    /// single failing item can't silently leave everything after it unflipped
    /// (which strands that item local-only and unable to sync). On any failure
    /// the flag is re-derived from what the items are *actually* in and the
    /// caller is told both what was attempted and where it ended up.
    public func setiCloudKeychainSyncEnabled(enabled: Bool) throws {
        printDebug("backupKeychainToiCloud(\(enabled)) — state before flip:")
        logCredentialVariantState(context: "before flip")

        let skipsDivergentPair: (String) -> Bool = { account in
            enabled && self.hasDivergentCredentialPair(account: account)
        }
        let failures = privateKeyManager.setKeysSynchronizable(enabled, skipping: skipsDivergentPair)
            + passwordManager.setPasswordSynchronizable(enabled, skipping: skipsDivergentPair)

        printDebug("backupKeychainToiCloud(\(enabled)) — state after flip:")
        logCredentialVariantState(context: "after flip")

        guard failures.isEmpty else {
            printDebug("backupKeychainToiCloud FAILURES: \(failures.joined(separator: "; "))")

            let actual = privateKeyManager.observedKeySyncState() ?? !enabled
            do {
                try backupStatusManager.writeBackupFlag(enabled: actual)
            } catch {
                printDebug("flip: could not correct backup flag:", error)
            }

            throw KeyManagerError.syncFlipFailed(
                attempted: enabled,
                actual: actual,
                details: failures.joined(separator: "; ")
            )
        }

        try backupStatusManager.writeBackupFlag(enabled: enabled)
    }

    // MARK: - Migrations

    public func migrateLegacyBackupStatusIfNeeded() {
        backupStatusManager.migrateLegacyBackupStatusIfNeeded()
    }

    @discardableResult
    public func migrateKeyLabelsToFingerprintsIfNeeded() throws -> Int {
        try privateKeyManager.migrateKeyLabelsToFingerprintsIfNeeded()
    }

    public func migrateLegacyKeysIfNeeded() throws {
        try privateKeyManager.migrateLegacyKeysIfNeeded()
    }

    // MARK: - Debugging

    public func dumpAllKeychainItems() {
        printDebug("--- Dumping All Keychain Items Accessible by App ---")

        let itemClasses: [CFString] = [
            kSecClassGenericPassword,
            kSecClassKey
        ]

        for itemClass in itemClasses {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]

            var items: CFTypeRef?
            let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &items)

            printDebug("\n--- Querying Class: \(itemClass) ---")

            if status == errSecSuccess {
                guard let foundItems = items as? [[String: Any]] else {
                    printDebug("  Result found, but failed to cast to [[String: Any]] for class \(itemClass).")
                    continue
                }

                if foundItems.isEmpty {
                    printDebug("  No items found for this class.")
                } else {
                    printDebug("  Found \(foundItems.count) item(s):")
                    for (index, item) in foundItems.enumerated() {
                        printDebug("    --- Item \(index + 1) ---")
                        for (key, value) in item {
                            var printableValue: String = "<Non-printable or complex value>"
                            if let dataValue = value as? Data {
                                if let stringValue = String(data: dataValue, encoding: .utf8) {
                                    printableValue = "'\(stringValue)' (String, \(dataValue.count) bytes)"
                                } else {
                                    printableValue = "<Data: \(dataValue.count) bytes>"
                                }
                            } else if let dateValue = value as? Date {
                                printableValue = "\(dateValue) (Date)"
                            } else if let boolValue = value as? Bool {
                                printableValue = "\(boolValue) (Bool)"
                            } else if let numberValue = value as? NSNumber {
                                printableValue = "\(numberValue) (Number - Bool: \(numberValue.boolValue))"
                            } else if let stringValue = value as? String {
                                printableValue = "'\(stringValue)' (String)"
                            } else {
                                printableValue = "\(value) (Type: \(type(of: value)))"
                            }

                            if key == (kSecAttrSynchronizable as String) {
                                var syncStatusDesc = "Unknown/Not Present"
                                if let boolValue = value as? Bool {
                                    syncStatusDesc = boolValue ? "Enabled (Bool: true)" : "Disabled (Bool: false)"
                                } else if let numberValue = value as? NSNumber {
                                     syncStatusDesc = numberValue.boolValue ? "Enabled (Number: \(numberValue))" : "Disabled (Number: \(numberValue))"
                                 } else if value is NSNull {
                                      syncStatusDesc = "Disabled (NSNull)"
                                 }
                                 printDebug("      \(key): \(syncStatusDesc)")
                            } else {
                                printDebug("      \(key): \(printableValue)")
                            }
                        }
                    }
                }
            } else if status == errSecItemNotFound {
                printDebug("  No items found for this class (errSecItemNotFound).")
            } else {
                printDebug("  Error querying class \(itemClass): OSStatus \(status)")
            }
        }
        printDebug("--- End Keychain Dump ---")
    }
}

extension KeychainManager {
    static func checkStatus(status: OSStatus, defaultError: KeyManagerError? = nil) throws {
        let throwDefault = defaultError ?? .unhandledError(determineOSStatus(status: status))
        switch status {
        case errSecItemNotFound:
            throw KeyManagerError.notFound
        case errSecDuplicateItem:
            throw KeyManagerError.keyExists
        case errSecSuccess:
            break
        default:
            throw throwDefault
        }
    }
}

private extension KeychainManager {

    // MARK: - Key Restore

    /// Heals key state after authentication when the active key can't be loaded.
    /// On a second device, the KVS-synced `currentKey` default may name a key
    /// that never reached this device, and the default key itself may still be
    /// derivable from the synced passphrase even if its keychain item hasn't
    /// arrived. Runs on every unlock, so key material that syncs in minutes
    /// after first launch is picked up on the next authentication.
    func attemptKeyRestoreAfterFailedLoad() {
        printDebug("attemptKeyRestoreAfterFailedLoad: snapshot \(credentialSnapshot()), currentKey default='\(UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String ?? "nil")'")
        if let activeKeyRef = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String,
           PrivateKey.isFingerprintLabel(activeKeyRef),
           keyWith(fingerprint: activeKeyRef) == nil {
            printDebug("Clearing stale currentKey '\(activeKeyRef)' — key not present on this device")
            UserDefaultUtils.removeObject(forKey: UserDefaultKey.currentKey)
        }

        do {
            let restored = try restoreDefaultKeyFromPassphraseIfNeeded()
            try privateKeyManager.getActiveKeyAndSet()
            printDebug("attemptKeyRestoreAfterFailedLoad: succeeded (restoredFromPassphrase=\(restored), currentKey='\(currentKey?.keychainLabel ?? "nil")')")
        } catch {
            printDebug("Key restore after failed load did not succeed:", error)
        }
    }

    // MARK: - Keychain Reads

    /// Fetches one specific variant (local or synced) of a generic-password
    /// item. All other reads in this class match either synchronizableAny or
    /// the flag-driven value, which can't distinguish coexisting variants.
    func genericPasswordData(account: String, synchronizable: Bool) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        ]
        var item: CFTypeRef?
        guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    // MARK: - Credential Conflicts

    /// True when a local and a synced copy of this generic-password account both
    /// exist and hold different bytes — a genuine credential conflict rather
    /// than the ordinary redundant duplicate a second device accumulates.
    func hasDivergentCredentialPair(account: String) -> Bool {
        guard let local = genericPasswordData(account: account, synchronizable: false),
              let synced = genericPasswordData(account: account, synchronizable: true) else {
            return false
        }
        return local != synced
    }

    /// Whether writes go to the iCloud keychain. Pinned like reads while a
    /// conflict resolution is active, so updates land on the credential set the
    /// user chose.
    var synchronizableForWrites: Bool {
        switch conflictResolution {
        case .preferLocal: return false
        case .preferSynced: return true
        case nil: break
        }
        return self.isSyncEnabled
    }
}

// Helper extension for Bool to Data conversion (if not already present)
extension Bool {
    var data: Data {
        var intValue = self ? 1 : 0
        return Data(bytes: &intValue, count: MemoryLayout<Int>.size)
    }
}

// Helper extension for Data to Bool conversion (needed for reading the flag later)
extension Data {
    var boolValue: Bool? {
        guard count == MemoryLayout<Int>.size else { return nil }
        return withUnsafeBytes { $0.load(as: Int.self) == 1 }
    }
}

// Added Helper extension for UUID to Data conversion
extension UUID {
    var data: Data {
        withUnsafeBytes(of: self.uuid) { Data($0) }
    }
}
