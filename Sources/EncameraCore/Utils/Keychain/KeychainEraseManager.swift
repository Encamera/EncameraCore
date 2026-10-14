//
//  KeychainEraseManager.swift
//  EncameraCore
//

import Foundation
import Security

/// Erases the app's keychain footprint and reports what survived an erase.
///
/// Owned by `KeychainManager`, which forwards the `KeyManager` erase calls here.
struct KeychainEraseManager {

    let keychainWrapper: KeychainWrapperProtocol
    let privateKeyManager: PrivateKeyManager
    let multiDeviceManager: MultiDeviceManager
    let passwordManager: KeychainPasswordManager

    /// Wipes this app's keychain footprint at the requested scope.
    ///
    /// `.deviceLocal` matches only `kSecAttrSynchronizable: false` items, so no
    /// deletion tombstone is created and the account's other devices keep their
    /// key, passphrase and password hash. `.accountWide` restores the historical
    /// `kSecAttrSynchronizableAny` sweep, which removes the credentials from
    /// every device on the iCloud account and cannot be undone.
    ///
    /// Known consequence of the device-local scope: when iCloud Backup & Sync is on,
    /// this device's copies of the key and passphrase *are* the synced items, so
    /// they survive a device-local reset. The keychain offers no way to drop a
    /// local copy of a synchronizable item without tombstoning it everywhere;
    /// removing them here would be exactly the account nuke this split exists to
    /// prevent. Turning backup off (or removing the device from iCloud) is the
    /// supported way to clear those.
    func clearKeychainData(scope: KeyDeletionScope) {
        let syncMatch: Any
        switch scope {
        case .deviceLocal:
            syncMatch = kCFBooleanFalse!
        case .accountWide:
            syncMatch = kSecAttrSynchronizableAny
        }

        let keychainClasses: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]

        for keychainClass in keychainClasses {
            let query: [String: Any] = [
                kSecClass as String: keychainClass,
                kSecAttrSynchronizable as String: syncMatch
            ]

            let status = keychainWrapper.secItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("Failed to delete items for class \(keychainClass): \(status)")
            }
        }

        privateKeyManager.deletePassphrase(syncMatch: syncMatch)

        // The backup status flag and the authentication configuration are both
        // hardcoded-synchronizable account state. Only an account-wide erase may
        // remove them; deleting them on a device-local reset would tell every
        // other device that backup was never enabled and that no passcode is set.
        switch scope {
        case .deviceLocal:
            try? clearLocalPasswordItems()
        case .accountWide:
            let backupStatusQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let backupStatusDeleteStatus = keychainWrapper.secItemDelete(backupStatusQuery as CFDictionary)
            if backupStatusDeleteStatus != errSecSuccess && backupStatusDeleteStatus != errSecItemNotFound {
                print("Failed to delete backup status flag item: \(backupStatusDeleteStatus)")
            }

            multiDeviceManager.deleteState()

            try? passwordManager.clearPassword()
        }

        privateKeyManager.clearActiveKey()
        print("Keychain data cleared (scope: \(scope))")
    }

    /// See `KeyManager.residualKeychainItemNames()`. Queries the same five classes
    /// the sweep does, with the same widest-match sync predicate, so a survivor the
    /// sweep should have taken cannot hide from the check that follows it.
    func residualKeychainItemNames() -> [String] {
        let classes: [(secClass: CFString, name: String)] = [
            (kSecClassGenericPassword, "GenericPassword"),
            (kSecClassInternetPassword, "InternetPassword"),
            (kSecClassCertificate, "Certificate"),
            (kSecClassKey, "Key"),
            (kSecClassIdentity, "Identity")
        ]

        var names: [String] = []
        for entry in classes {
            let query: [String: Any] = [
                kSecClass as String: entry.secClass,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            var result: CFTypeRef?
            guard keychainWrapper.secItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            for item in items {
                let name = (item[kSecAttrAccount as String] as? String)
                    ?? (item[kSecAttrLabel as String] as? String)
                    ?? (item[kSecAttrService as String] as? String)
                    ?? (item[kSecAttrApplicationTag as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    ?? "<unnamed>"
                names.append("\(entry.name)|\(name)")
            }
        }
        return names.sorted()
    }
}

private extension KeychainEraseManager {

    /// Removes only this device's non-synchronizable password hash and legacy
    /// passcode-type items. Unlike `clearPassword()` it does not rewrite the
    /// always-synced `AuthenticationConfiguration`, because that write would
    /// propagate to every device on the account.
    func clearLocalPasswordItems() throws {
        let accounts = [KeychainConstants.account, KeychainConstants.passcodeTypeKeyItem]
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanFalse!
            ]
            let status = keychainWrapper.secItemDelete(query as CFDictionary)
            if status != errSecItemNotFound {
                try KeychainManager.checkStatus(status: status)
            }
        }
    }
}
