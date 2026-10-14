//
//  PrivateKeyManager.swift
//  EncameraCore
//

import Foundation
import Sodium
import Combine
import Security
import UIKit

/// Owns the private key items in the keychain: deriving, saving, looking up,
/// deleting and migrating keys, the passphrase item they are derived from, and
/// which key is active.
///
/// Owned by `KeychainManager`, which forwards the `KeyManager` key calls here.
/// Writes take the sync value from the caller because whether a write is
/// synchronizable is decided by the backup flag, which `KeychainManager` owns.
final class PrivateKeyManager: DebugPrintable {

    private(set) var currentKey: PrivateKey? {
        didSet {
            keySubject.send(currentKey)
        }
    }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> {
        keySubject.eraseToAnyPublisher()
    }

    private let keychainWrapper: KeychainWrapperProtocol
    private let syncFlipper: KeychainItemSyncFlipper
    private let sodium = Sodium()
    private let keySubject: PassthroughSubject<PrivateKey?, Never> = .init()

    init(keychainWrapper: KeychainWrapperProtocol) {
        self.keychainWrapper = keychainWrapper
        self.syncFlipper = KeychainItemSyncFlipper(keychainWrapper: keychainWrapper)
    }

    // MARK: - Creating keys

    @discardableResult func generateKeyUsingRandomWords(name: String, synchronizable: Bool) throws -> PrivateKey {

        guard let dictionaryPath = Bundle.main.path(forResource: "dictionary", ofType: "txt"),
              let dictionaryContent = try? String(contentsOfFile: dictionaryPath) else {
            throw KeyManagerError.dictionaryLoadError
        }

        let words = dictionaryContent.components(separatedBy: .newlines).filter { !$0.isEmpty && $0.lengthOfBytes(using: .utf8) > 4 }

        guard words.count >= 10 else {
            throw KeyManagerError.dictionaryTooSmall
        }

        let selectedWords = (0..<10).compactMap { _ in words.randomElement()?.lowercased() }

        return try generateKeyFromPasswordComponentsAndSave(selectedWords, name: name, synchronizable: synchronizable)
    }

    @discardableResult func saveKeyWithPassphrase(passphrase: KeyPassphrase, synchronizable: Bool) throws -> PrivateKey {

        return try generateKeyFromPasswordComponentsAndSave(passphrase.words, name: AppConstants.defaultKeyName, synchronizable: synchronizable)
    }

    /// Derives a key from passphrase components without writing anything to the
    /// keychain. Words 1-4 are the salt, the rest the password input to pwHash.
    func deriveKey(from components: [String], name: String) throws -> PrivateKey {
        guard !components.isEmpty else {
            throw KeyManagerError.invalidInput
        }

        try validateKeyName(name: name)
        let splitIndex = 4
        let saltComponents = components.prefix(splitIndex)
        let saltString = saltComponents.joined(separator: "-")
        let passwordComponents = components.dropFirst(splitIndex)
        let password = passwordComponents.joined(separator: "-")

        let saltBytes = Array(saltString.bytes.prefix(Sodium().pwHash.SaltBytes))
        if saltBytes.count < Sodium().pwHash.SaltBytes {
            throw KeyManagerError.invalidSalt
        }

        let keyLength = Sodium().secretStream.xchacha20poly1305.KeyBytes
        guard let keyBytes = sodium.pwHash.hash(outputLength: keyLength,
                                                passwd: password.bytes,
                                                salt: saltBytes,
                                                opsLimit: sodium.pwHash.OpsLimitInteractive,
                                                memLimit: sodium.pwHash.MemLimitInteractive) else {
            throw KeyManagerError.keyDerivationFailed
        }

        return PrivateKey(name: name, keyBytes: keyBytes, creationDate: Date())
    }

    @discardableResult func generateKeyFromPasswordComponentsAndSave(_ components: [String], name: String, synchronizable: Bool) throws -> PrivateKey {
        let key = try deriveKey(from: components, name: name)
        let fullPassword = components.joined(separator: "-")
        let syncValue = Self.syncValue(synchronizable)

        do {
            try save(key: key, setNewKeyToCurrent: true, synchronizable: synchronizable)
        } catch {
            self.printDebug("Could not save key", error)
            throw error
        }

        let passphraseData = fullPassword.data(using: .utf8)!
        let passphraseQuery = queryForPassphrase(additionalQuery: [:])

        var withOptions: [String: Any] = passphraseQuery
        withOptions[kSecReturnData as String] = true

        var item: CFTypeRef?
        let queryResult = keychainWrapper.secItemCopyMatching(withOptions as CFDictionary, &item)

        switch queryResult {
        case errSecSuccess:
            let updateQuery: [String: Any] = [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValue,
            ]
            let updateStatus = keychainWrapper.secItemUpdate(passphraseQuery as CFDictionary, updateQuery as CFDictionary)

            if updateStatus != errSecItemNotFound {
                try KeychainManager.checkStatus(status: updateStatus)
            }
        case errSecItemNotFound:
            let addQuery = queryForPassphrase(additionalQuery: [
                kSecValueData as String: passphraseData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValue
            ])
            let addStatus = keychainWrapper.secItemAdd(addQuery as CFDictionary, nil)
            try KeychainManager.checkStatus(status: addStatus)
        default:
            try KeychainManager.checkStatus(status: queryResult)
        }


        return key

    }

    func validateKeyName(name: String) throws {
        guard name.count > KeychainConstants.minKeyLength else {
            throw KeyManagerError.keyNameError
        }
    }

    func save(key: PrivateKey, setNewKeyToCurrent: Bool, synchronizable: Bool) throws {
        let syncValue = Self.syncValue(synchronizable)
        var query = key.keychainQueryDictForKeychain
        query[kSecAttrSynchronizable as String] = syncValue

        if let baseQuery = existingKeyItemQuery(for: key) {
            // Deliberately does NOT write kSecAttrCreationDate: storedKeys()
            // sorts by it, so refreshing it on every save reorders the library.
            var updateQuery: [String: Any] = [
                kSecValueData as String: key.keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValue,
            ]
            updateQuery.merge(key.keychainIdentityAttributes) { current, _ in current }
            let updateStatus = keychainWrapper.secItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
            try KeychainManager.checkStatus(status: updateStatus)

        } else {
            let addStatus = keychainWrapper.secItemAdd(query as CFDictionary, nil)
            try KeychainManager.checkStatus(status: addStatus)
        }

        if setNewKeyToCurrent {
            try setActiveKey(key)
        }
    }

    // MARK: - Passphrase

    func retrieveKeyPassphrase(conflictResolution: KeychainManager.CredentialConflictResolution?) throws -> KeyPassphrase {
        var additionalQuery: [String: Any] = [
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // While a conflict resolution is active, pin the read to the chosen
        // credential set — with both a local and a synced passphrase present,
        // the default synchronizableAny match is nondeterministic.
        switch conflictResolution {
        case .preferLocal:
            additionalQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        case .preferSynced:
            additionalQuery[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        case nil:
            break
        }
        let query: [String: Any] = queryForPassphrase(additionalQuery: additionalQuery)

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeyManagerError.notFound
        }

        guard let result = item as? [String: Any],
              let data = result[kSecValueData as String] as? Data,
              let passphrase = String(data: data, encoding: .utf8) else {
            throw KeyManagerError.dataError
        }

        let words = passphrase.components(separatedBy: "-")

        let keyPassphrase = KeyPassphrase(words: words)

        return keyPassphrase
    }

    func keyPassphraseExists() -> Bool {
        let query = queryForPassphrase(additionalQuery: [
            kSecReturnData as String: true
        ])
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              !data.isEmpty else {
            if status != errSecItemNotFound {
                printDebug("keyPassphraseExists: status \(status) (\(determineOSStatus(status: status)))")
            }
            return false
        }
        return true
    }

    /// Deletes the passphrase item. `syncMatch` is the `kSecAttrSynchronizable`
    /// predicate, so the caller decides whether synced copies go too.
    func deletePassphrase(syncMatch: Any) {
        let passphraseQuery = queryForPassphrase(additionalQuery: [
            kSecAttrSynchronizable as String: syncMatch
        ])
        let passphraseStatus = keychainWrapper.secItemDelete(passphraseQuery as CFDictionary)
        if passphraseStatus != errSecSuccess && passphraseStatus != errSecItemNotFound {
            print("Failed to delete passphrase item: \(passphraseStatus)")
        }
    }

    // MARK: - Looking up keys

    func keyWith(name: String) -> PrivateKey? {

        let keys = try? storedKeys()
        return keys?.first(where: {$0.name == name})
    }

    /// Identity lookup. Names are display metadata and may repeat across keys;
    /// the fingerprint is what uniquely identifies a key.
    func keyWith(fingerprint: String) -> PrivateKey? {
        let keys = try? storedKeys()
        return keys?.first(where: { $0.keychainLabel == fingerprint })
    }

    @MainActor
    func keyWith(uuid: UUID) -> PrivateKey? {
        if UIApplication.shared.applicationState == .background,
           let currentKey = currentKey,
           currentKey.uuid == uuid {
            printDebug("Returning cached key in background for UUID: \(uuid)")
            return currentKey
        }

        let keys = try? storedKeys()
        return keys?.first(where: {$0.uuid == uuid})
    }

    func storedKeys() throws -> [PrivateKey] {

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        return try keysFromQuery(query: query)
    }

    // MARK: - Deleting keys

    /// Removes one key from the library.
    ///
    /// Refuses to remove the last remaining key or the key that is currently
    /// active — both throw rather than silently no-op, because a caller that
    /// hits either has a logic error and would otherwise leave the app with no
    /// usable key.
    func deleteKey(fingerprint: String, scope: KeyDeletionScope) throws {
        let keys = try storedKeys()
        guard keys.contains(where: { $0.keychainLabel == fingerprint }) else {
            throw KeyManagerError.notFound
        }
        guard keys.count > 1 else {
            throw KeyManagerError.keyDeletionFailed
        }
        let activeFingerprint: String?
        if let pointer = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String {
            activeFingerprint = PrivateKey.isFingerprintLabel(pointer)
                ? pointer
                : keys.first(where: { $0.name == pointer })?.keychainLabel
        } else {
            activeFingerprint = currentKey?.keychainLabel
        }
        if activeFingerprint == fingerprint {
            throw KeyManagerError.keyDeletionFailed
        }

        guard let labelData = fingerprint.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: labelData,
            kSecAttrApplicationLabel as String: labelData,
        ]
        switch scope {
        case .deviceLocal:
            // Targets only the non-synchronizable copy, so the deletion is not
            // tombstoned to the rest of the account.
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        case .accountWide:
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        let status = keychainWrapper.secItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            printDebug("deleteKey: FAILED fingerprint=\(fingerprint) scope=\(scope) status=\(status) (\(determineOSStatus(status: status)))")
            throw KeyManagerError.keyDeletionFailed
        }
        printDebug("deleteKey: removed fingerprint=\(fingerprint) scope=\(scope)")
    }

    // MARK: - Active key

    func setActiveKey(_ name: KeyName?) throws {

        guard let name = name else {
            currentKey = nil
            UserDefaultUtils.removeObject(forKey: UserDefaultKey.currentKey)
            return
        }
        guard let key = try? getKey(by: name) else {
            throw KeyManagerError.notFound
        }
        try setActiveKey(key)
    }

    /// Pins the current key by fingerprint. Display names are no longer unique,
    /// so a name is not enough to identify which key is current.
    func setActiveKey(_ key: PrivateKey) throws {
        currentKey = key
        UserDefaultUtils.set(key.keychainLabel, forKey: UserDefaultKey.currentKey)
    }

    func getActiveKey() throws -> PrivateKey {
        guard let activeKeyRef = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String else {
            guard let firstStoredKey = try storedKeys().first else {
                throw KeyManagerError.notFound
            }
            try setActiveKey(firstStoredKey)
            return firstStoredKey
        }
        if PrivateKey.isFingerprintLabel(activeKeyRef), let key = keyWith(fingerprint: activeKeyRef) {
            return key
        }
        let key = try getKey(by: activeKeyRef)
        try setActiveKey(key)
        return key
    }

    /// Re-pins the resolved active key by its own identity. Deliberately NOT
    /// `setActiveKey(keyObject.name)`: a name round-trip goes back through
    /// `getKey(by:)` -> `keyWith(name:)` -> `storedKeys().first(where:)`, and
    /// `storedKeys()` sorts ascending by creation date, so the name lookup
    /// resolves to the OLDEST key carrying that name. Once a library holds
    /// several keys all named `encamera_default_key`, that runs on
    /// every unlock and silently demotes whatever was pinned, such as a
    /// returning user's freshly imported key. `testActiveKeyPointerSurvivesRepeatedAuthentication` pins this.
    func getActiveKeyAndSet() throws {
        let keyObject = try getActiveKey()
        try setActiveKey(keyObject)
    }

    func getKey(by keyName: KeyName) throws -> PrivateKey {



        // Scans the library rather than querying by label: the label now carries
        // the fingerprint, not the name. Ambiguous by nature once two keys share
        // a display name — returns the first in `storedKeys()` order.
        guard let key = keyWith(name: keyName) else {
            throw KeyManagerError.notFound
        }
        return key
    }

    // MARK: - Migration

    /// Relabels name-addressed key items to fingerprint-addressed ones, in
    /// place. Idempotent — items already carrying a fingerprint label are left
    /// untouched, so it is safe to run on every launch.
    ///
    /// Uses `SecItemUpdate` exclusively and never `SecItemDelete`: deleting a
    /// synchronizable item tombstones it account-wide and the deletion
    /// propagates to every other device. Each item is targeted in its
    /// own sync scope so a local and a synced copy of the same key are
    /// relabelled independently rather than one clobbering the other.
    @discardableResult
    func migrateKeyLabelsToFingerprintsIfNeeded() throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return 0 }
        try KeychainManager.checkStatus(status: status)
        guard let items = item as? [[String: Any]] else { return 0 }

        var relabelled = 0
        for keychainItem in items {
            guard let labelData = keychainItem[kSecAttrLabel as String] as? Data,
                  let existingLabel = String(data: labelData, encoding: .utf8) else {
                continue
            }
            guard !PrivateKey.isFingerprintLabel(existingLabel) else {
                continue
            }
            guard let key = try? PrivateKey(keychainItem: keychainItem) else {
                printDebug("migrateKeyLabels: skipping undecodable item labelled \(existingLabel)")
                continue
            }

            let isSynced = (keychainItem[kSecAttrSynchronizable as String] as? Bool) ?? false
            let targetQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: labelData,
                kSecAttrSynchronizable as String: isSynced ? kCFBooleanTrue! : kCFBooleanFalse!
            ]
            let updateStatus = keychainWrapper.secItemUpdate(
                targetQuery as CFDictionary,
                key.keychainIdentityAttributes as CFDictionary
            )
            if updateStatus == errSecSuccess {
                relabelled += 1
                printDebug("migrateKeyLabels: relabelled \(existingLabel) -> \(key.keychainLabel) (synced=\(isSynced))")
            } else {
                printDebug("migrateKeyLabels: FAILED to relabel \(existingLabel) — status \(updateStatus) (\(determineOSStatus(status: updateStatus)))")
            }
        }

        // Re-pin an existing name-based pointer onto the fingerprint. Guarded on
        // a pointer already being set: getActiveKey() promotes the first stored
        // key when there is none, and migration must never choose a current key.
        if relabelled > 0,
           let pointer = UserDefaultUtils.value(forKey: UserDefaultKey.currentKey) as? String,
           !PrivateKey.isFingerprintLabel(pointer) {
            _ = try? getActiveKey()
        }
        printDebug("migrateKeyLabels: relabelled \(relabelled) of \(items.count) key items")
        return relabelled
    }

    func migrateLegacyKeysIfNeeded() throws {
        try migrateKeyLabelsToFingerprintsIfNeeded()

        let keys = try storedKeys()

        guard !keys.isEmpty else {
            printDebug("No keys found, skipping migration")
            return
        }

        printDebug("Starting migration for \(keys.count) keys")

        for key in keys {
            do {
                let originalSyncStatus = try isKeyItemSynced(fingerprint: key.keychainLabel)

                try saveKeyPreservingSync(key: key, syncStatus: originalSyncStatus)
                printDebug("Successfully processed key: \(key.name)")
            } catch {
                printDebug("Failed to migrate key \(key.name): \(error)")
                throw error
            }
        }

        printDebug("Migration completed for \(keys.count) keys")
    }

    // MARK: - iCloud sync

    /// Moves every Encamera key item and the passphrase item on or off the
    /// iCloud keychain. Each item is flipped independently, so one failure
    /// can't leave the items after it unflipped; returns a line per failure.
    /// The passphrase is left unflipped when `shouldSkip` returns true for it.
    func setKeysSynchronizable(_ synchronizable: Bool, skipping shouldSkip: (String) -> Bool) -> [String] {
        var failures: [String] = []

        do {
            for identity in try encameraKeyIdentities() {
                let label = (identity[kSecAttrLabel as String] as? Data)
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "<unlabelled>"
                do {
                    try syncFlipper.setSynchronizable(synchronizable,
                                                      forItemMatching: identity,
                                                      description: "key \(label)")
                } catch {
                    printDebug("flip: key '\(label)' FAILED:", error)
                    failures.append("key \(label): \(error)")
                }
            }
        } catch {
            printDebug("flip: could not enumerate key items:", error)
            failures.append("keyItems: \(error)")
        }

        failures += syncFlipper.setSynchronizable(synchronizable, genericCredentials: [
            (KeychainConstants.passPhraseKeyItem, "key passphrase")
        ], skipping: shouldSkip)
        return failures
    }

    /// Moves a single key on or off the iCloud keychain. Routed through
    /// `KeychainItemSyncFlipper` like every other flip — a one-shot
    /// `SecItemUpdate` cannot flip a key that has both a local and an
    /// iCloud-delivered copy, which is the normal state of any second device.
    /// The flipper writes the target copy before deleting the other, so no
    /// interruption can leave the key material gone.
    func setSynchronizable(_ synchronizable: Bool, for key: PrivateKey) throws {
        guard var query = existingKeyItemQuery(for: key) else {
            throw KeyManagerError.notFound
        }
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query.removeValue(forKey: kSecReturnData as String)

        try syncFlipper.setSynchronizable(synchronizable,
                                          forItemMatching: query,
                                          description: "key \(key.keychainLabel) ('\(key.name)')")
        printDebug("Key updated: \(key.name), iCloud: \(synchronizable)")
    }

    /// The sync state the stored key items are observably in, independent of
    /// what the backup flag claims. `true` only when every key item is
    /// synchronizable, so a half-flipped library reads as "not enabled" — the
    /// conservative answer, since it makes subsequent writes stay local rather
    /// than assume a sync that did not happen. `nil` when there are no keys to
    /// judge by.
    ///
    /// Judged on the raw `kSecClassKey` items rather than on `storedKeys()`:
    /// a key item that fails to decode — a corrupt or not-yet-migrated
    /// blob — is still a key sitting in the keychain in some sync scope, and a
    /// local one of those means the library is not fully synced. Decoding first
    /// would make it invisible and report the library as clean.
    ///
    /// `KeychainManager.isSyncEnabled` calls this on its `.notSet` path, so
    /// nothing this touches may consult `isSyncEnabled`, or the loop closes
    /// into unbounded recursion. Querying `SecItem` directly keeps that guaranteed.
    func observedKeySyncState() -> Bool? {
        func encameraKeyItemExists(synchronizable: CFBoolean) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrSynchronizable as String: synchronizable,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var item: CFTypeRef?
            guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let items = item as? [[String: Any]] else {
                return false
            }
            return items.contains(where: Self.isEncameraKeyItem)
        }

        let hasLocalKey = encameraKeyItemExists(synchronizable: kCFBooleanFalse!)
        let hasSyncedKey = encameraKeyItemExists(synchronizable: kCFBooleanTrue!)
        guard hasLocalKey || hasSyncedKey else {
            return nil
        }
        return !hasLocalKey
    }

    // MARK: - Item queries

    /// True when a key with these bytes is already stored, in either sync scope.
    func keyItemExists(fingerprint: String) -> Bool {
        guard var query = try? keyIdentityQuery(forFingerprint: fingerprint) else {
            return false
        }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychainWrapper.secItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Locates the stored item for `key`, preferring fingerprint identity and
    /// falling back to the legacy name label so that installs which have not yet
    /// run `migrateKeyLabelsToFingerprintsIfNeeded()` still update in place
    /// instead of gaining a duplicate.
    func existingKeyItemQuery(for key: PrivateKey) -> [String: Any]? {
        if keyItemExists(fingerprint: key.keychainLabel) {
            return try? keyIdentityQuery(forFingerprint: key.keychainLabel)
        }
        guard var legacy = legacyKeyItemQuery(forName: key.name) else { return nil }
        var probe = legacy
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        probe[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard keychainWrapper.secItemCopyMatching(probe as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        // A name match alone is not identity. Every production key is called
        // `encamera_default_key`, so importing a second key phrase on an
        // install that has not yet been relabelled would otherwise update the
        // existing item in place and destroy the material every already-encrypted
        // file depends on. Only reuse the legacy item when its bytes
        // really are this key's.
        guard let data = item as? Data,
              Self.storedKeyBytes(from: data) == key.keyBytes else {
            return nil
        }
        legacy.removeValue(forKey: kSecMatchLimit as String)
        return legacy
    }
}

private extension PrivateKeyManager {
    static func syncValue(_ synchronizable: Bool) -> CFBoolean {
        synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
    }

    func queryForPassphrase(additionalQuery: [String: Any]? = nil) -> [String: Any] {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passPhraseKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        if let additionalQuery {
            return baseQuery.merging(additionalQuery, uniquingKeysWith: { $1 })
        }

        return baseQuery
    }

    /// Targets a single key item by fingerprint identity, regardless of its
    /// sync state, for update and existence probes.
    func keyIdentityQuery(forFingerprint fingerprint: String) throws -> [String: Any] {
        guard let labelData = fingerprint.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        return [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: labelData,
            kSecAttrApplicationLabel as String: labelData,
            // Existence probes must use Any, never syncQueryValueForReads: with
            // the backup flag disabled, a synced item would be invisible and
            // save() would SecItemAdd over an item that already exists.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    /// Targets a pre-migration item, which is still labelled with its display
    /// name rather than a fingerprint.
    func legacyKeyItemQuery(forName name: KeyName) -> [String: Any]? {
        guard let nameData = name.data(using: .utf8) else { return nil }
        return [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: nameData,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    /// Key material out of a stored `kSecValueData`, in either shipped
    /// encoding: the current JSON `KeyCore` blob, or the pre-migration raw
    /// bytes that `migrateLegacyKeysIfNeeded()` still upgrades. Mirrors the
    /// same fallback in `PrivateKey.init(keychainItem:)`.
    static func storedKeyBytes(from data: Data) -> KeyBytes {
        if let decoded = try? PrivateKey(name: AppConstants.defaultKeyName, keyData: data, creationDate: Date()) {
            return decoded.keyBytes
        }
        return Array(data)
    }

    func keysFromQuery(query: [String: Any]) throws -> [PrivateKey]  {
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return []
        }
        try KeychainManager.checkStatus(status: status)

        guard let keychainItems = item as? [[String: Any]] else {
            printDebug("Keychain query succeeded but failed to cast items.")
            return []
        }
        let keys = keychainItems.compactMap { keychainItem -> PrivateKey? in
            do {
                return try PrivateKey(keychainItem: keychainItem)
            } catch {
                return nil
            }
        }.sorted(by: {
            $1.creationDate.compare($0.creationDate) == .orderedDescending
        })
        return keys
    }

    /// A base query per distinct Encamera key item the app can see, synced
    /// copies included and deduplicated — one identity normally has both a
    /// local and an iCloud-delivered copy.
    func encameraKeyIdentities() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        try KeychainManager.checkStatus(status: status)
        guard let items = item as? [[String: Any]] else {
            return []
        }

        var identities: [[String: Any]] = []
        var seen: [Data] = []
        for attributes in items where Self.isEncameraKeyItem(attributes) {
            guard let tagData = attributes[kSecAttrApplicationTag as String] as? Data,
                  let label = attributes[kSecAttrLabel as String] as? Data else { continue }
            if seen.contains(label) { continue }
            seen.append(label)

            // The full identity, not just the label: for `kSecClassKey` the
            // primary key is applicationLabel/applicationTag/keyType/…, so a
            // query on `kSecAttrLabel` alone can match a key that is not this
            // one, and an add built from it would write an item the app can no
            // longer recognize as its own.
            var identity: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: label,
                kSecAttrApplicationTag as String: tagData
            ]
            if let applicationLabel = attributes[kSecAttrApplicationLabel as String] {
                identity[kSecAttrApplicationLabel as String] = applicationLabel
            }
            identities.append(identity)
        }
        return identities
    }

    /// Whether a `kSecClassKey` item is one of Encamera's own keys, by
    /// `kSecAttrApplicationTag`, which `PrivateKey.keychainIdentityAttributes`
    /// writes as `"\(KeychainConstants.applicationTag).\(name)"`. The tag can't
    /// be matched server-side by prefix, so callers enumerate and filter. A
    /// foreign key item written by anything else sharing the access group is
    /// not ours to judge or move.
    static func isEncameraKeyItem(_ attributes: [String: Any]) -> Bool {
        guard let tagData = attributes[kSecAttrApplicationTag as String] as? Data,
              let tag = String(data: tagData, encoding: .utf8) else {
            return false
        }
        return tag.hasPrefix(KeychainConstants.applicationTag)
    }

    func saveKeyPreservingSync(key: PrivateKey, syncStatus: Bool) throws {
        var query = key.keychainQueryDictForKeychain
        query[kSecAttrSynchronizable as String] = syncStatus ? kCFBooleanTrue! : kCFBooleanFalse!

        if let baseQuery = existingKeyItemQuery(for: key) {
            // Key exists, update it. Creation date is deliberately left alone —
            // storedKeys() sorts by it.
            var updateQuery: [String: Any] = [
                kSecValueData as String: key.keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncStatus ? kCFBooleanTrue! : kCFBooleanFalse!,
            ]
            updateQuery.merge(key.keychainIdentityAttributes) { current, _ in current }
            let updateStatus = keychainWrapper.secItemUpdate(baseQuery as CFDictionary, updateQuery as CFDictionary)
            try KeychainManager.checkStatus(status: updateStatus)
        } else {
            let addStatus = keychainWrapper.secItemAdd(query as CFDictionary, nil)
            try KeychainManager.checkStatus(status: addStatus)
        }
    }

    func isKeyItemSynced(fingerprint: String) throws -> Bool {
        var query = try keyIdentityQuery(forFingerprint: fingerprint)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                return false
            } else {
                throw KeyManagerError.unhandledError("Error checking sync status: \(status)")
            }
        }

        guard let attributes = item as? [String: Any] else {
            return false
        }

        let syncAttribute = attributes[kSecAttrSynchronizable as String]

        if let isSyncedBool = syncAttribute as? Bool {
            return isSyncedBool
        } else if let isSyncedNum = syncAttribute as? NSNumber {
            return isSyncedNum.boolValue
        }

        return false
    }

    func updateKeyQuery(forFingerprint fingerprint: String) throws -> CFDictionary {
        return try keyIdentityQuery(forFingerprint: fingerprint) as CFDictionary
    }
}
