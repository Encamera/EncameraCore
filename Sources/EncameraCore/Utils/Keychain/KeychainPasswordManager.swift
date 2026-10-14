//
//  KeychainPasswordManager.swift
//  EncameraCore
//

import Foundation
import Sodium
import Security

/// Owns the app password: its hash, the passcode type, and the
/// `AuthenticationConfiguration` record the passcode type is stored in.
///
/// Owned by `KeychainManager`, which forwards the `KeyManager` password calls
/// here. Writes take the sync value from the caller because whether a write is
/// synchronizable is decided by the backup flag, which `KeychainManager` owns.
struct KeychainPasswordManager: DebugPrintable {

    let keychainWrapper: KeychainWrapperProtocol

    var passcodeType: PasscodeType {
        if passwordExists() == false {
            return .none
        }

        if let storedPasscodeType = try? retrievePasscodeTypeFromKeychain(), passwordExists() {
            return storedPasscodeType
        }

        let defaultPasscodeType = PasscodeType.pinCode(length: AppConstants.defaultPinCodeLength)
        try? savePasscodeTypeToKeychain(defaultPasscodeType)
        return defaultPasscodeType
    }

    private let sodium = Sodium()

    /// The value for `kSecAttrSynchronizable` in READ queries.
    ///
    /// A chosen conflict resolution still pins reads to one credential set, so
    /// that two genuinely different coexisting credentials don't make lookups
    /// nondeterministic — that pin is a decision the user made.
    ///
    /// Absent one it is always "either". It used to fall back to narrowing by
    /// the backup flag — synced items when backup was on, local ones when off —
    /// which meant any disagreement between the flag and an item made that item
    /// invisible to the app. Not a theoretical state: build 1087 wrote the flag
    /// and then failed to move the items, and the on-device rig reproduced the
    /// consequence directly — the flag read ON, `encamera_default_key` existed
    /// only as a local copy, and the app could not load its own key ("Error
    /// during initial key setup: notFound") even though `storedKeys()`, which
    /// always queried both, could see it perfectly well.
    ///
    /// Reading both makes the app find its key whatever state a previous
    /// version left behind. Ambiguity is bounded: `setSynchronizable` collapses
    /// an item to a single copy whenever backup is toggled.
    private var syncQueryValueForReads: CFTypeRef {
        switch KeychainManager.CredentialConflictResolution.stored {
        case .preferLocal: return kCFBooleanFalse!
        case .preferSynced: return kCFBooleanTrue!
        case nil: return kSecAttrSynchronizableAny
        }
    }

    /// Moves the password hash and the legacy passcode-type item on or off the
    /// iCloud keychain. Each item is flipped independently; returns a line per
    /// failure. The `AuthenticationConfiguration` is always synchronizable and
    /// is never flipped. Accounts for which `shouldSkip` returns true are left
    /// unflipped.
    func setPasswordSynchronizable(_ synchronizable: Bool, skipping shouldSkip: (String) -> Bool) -> [String] {
        KeychainItemSyncFlipper(keychainWrapper: keychainWrapper)
            .setSynchronizable(synchronizable, genericCredentials: [
                (KeychainConstants.passcodeTypeKeyItem, "passcode type"),
                (KeychainConstants.account, "password hash"),
            ], skipping: shouldSkip)
    }

    func passwordExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let existingItem = item as? [String: Any],
              let data = existingItem[kSecValueData as String] as? Data,
              !data.isEmpty else {
            if status != errSecItemNotFound {
                printDebug("passwordExists: status \(status) (\(determineOSStatus(status: status)))")
            }
            return false
        }
        return true
    }

    func clearPassword() throws {
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let passwordStatus = keychainWrapper.secItemDelete(passwordQuery as CFDictionary)
        if passwordStatus != errSecItemNotFound {
            try KeychainManager.checkStatus(status: passwordStatus)
        }

        let passcodeTypeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let passcodeTypeStatus = keychainWrapper.secItemDelete(passcodeTypeQuery as CFDictionary)
        if passcodeTypeStatus != errSecItemNotFound {
            try KeychainManager.checkStatus(status: passcodeTypeStatus)
        }

        if var config = getAuthenticationConfiguration(), let type = config.passcodeType {
            config.removeAuthenticationType(.passcode(type))
            try setAuthenticationConfiguration(config: config)
        }
    }
    
    func setPassword(_ password: String, type: PasscodeType, synchronizable: Bool) throws {
        let hashed = try hashFrom(password: password)
        try setPasswordHash(hash: hashed, synchronizable: synchronizable)
        try savePasscodeTypeToKeychain(type)
    }

    func setOrUpdatePassword(_ password: String, type: PasscodeType, synchronizable: Bool) throws {
        let hashed = try hashFrom(password: password)
        let syncValue = Self.syncValue(synchronizable)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecAttrSynchronizable as String: syncValue
        ]

        let update: [String: Any] = [
            kSecValueData as String: hashed,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: syncValue
        ]

        let status = keychainWrapper.secItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            try setPassword(password, type: type, synchronizable: synchronizable)
        } else {
            try KeychainManager.checkStatus(status: status)
            try savePasscodeTypeToKeychain(type)
        }
    }

    func changePassword(newPassword: String, existingPassword: String, type: PasscodeType, synchronizable: Bool) throws {
        guard try checkPassword(existingPassword) == true else {
            throw KeyManagerError.invalidPassword
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        let deletePasswordStatus = keychainWrapper.secItemDelete(query as CFDictionary)
        do {
            try KeychainManager.checkStatus(status: deletePasswordStatus)
        } catch {
            printDebug("Clearing password failed", error)
        }
        try setPassword(newPassword, type: type, synchronizable: synchronizable)
    }

    func getPasswordHash() throws -> Data  {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: syncQueryValueForReads
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        do {
            try KeychainManager.checkStatus(status: status)
            guard let item = item, let passwordData = item as? Data else {
                throw KeyManagerError.notFound
            }
            return passwordData
        } catch let managerError as KeyManagerError {
            if case .notFound = managerError {
                throw KeyManagerError.invalidPassword
            } else {
                throw managerError
            }
        }
    }

    func setPasswordHash(hash: Data, synchronizable: Bool) throws {
        let syncValue = Self.syncValue(synchronizable)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecValueData as String: hash,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: syncValue
        ]
        let setPasswordStatus = keychainWrapper.secItemAdd(query as CFDictionary, nil)

        if setPasswordStatus == errSecDuplicateItem {
             let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: KeychainConstants.account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: hash,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecAttrSynchronizable as String: syncValue
            ]
            let updateStatus = keychainWrapper.secItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            try KeychainManager.checkStatus(status: updateStatus, defaultError: .keyUpdateFailed)
        } else {
            try KeychainManager.checkStatus(status: setPasswordStatus)
        }

    }

    func checkPassword(_ password: String) throws -> Bool {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        do {
            try KeychainManager.checkStatus(status: status)
            let passwordData = try getPasswordHash()
            guard let hashString = String(data: passwordData, encoding: .utf8) else {
                throw KeyManagerError.dataError
            }
            let passwordBytes = password.bytes
            let passwordMatch = sodium.pwHash.strVerify(hash: hashString, passwd: passwordBytes)
            if passwordMatch != true {
                throw KeyManagerError.invalidPassword
            }
            return passwordMatch
        }
        catch let managerError as KeyManagerError {
            if case .notFound = managerError {
                throw KeyManagerError.invalidPassword
            } else {
                throw managerError
            }
        }
        catch {
            printDebug("error checking password", error)
        }
        return false
    }

    func getAuthenticationConfiguration() -> AuthenticationConfiguration? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.authenticationConfiguration,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                printDebug("getAuthenticationConfiguration: query failed with status \(status) (\(determineOSStatus(status: status)))")
            }
            return nil
        }

        guard let data = item as? Data,
              let config = try? JSONDecoder().decode(AuthenticationConfiguration.self, from: data) else {
            printDebug("getAuthenticationConfiguration: Could not decode authentication configuration")
            return nil
        }

        return config
    }

    func setAuthenticationConfiguration(config: AuthenticationConfiguration) throws {

        guard let encoded = try? JSONEncoder().encode(config) else {
            printDebug("setAuthenticationConfiguration: Could not encode authentication configuration")
            throw KeyManagerError.dataError
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.authenticationConfiguration,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.authenticationConfiguration,
            kSecValueData as String: encoded,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        var status = keychainWrapper.secItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let newAttributes: [String: Any] = [
                kSecValueData as String: encoded
            ]
            status = keychainWrapper.secItemUpdate(updateQuery as CFDictionary, newAttributes as CFDictionary)
        }

        try KeychainManager.checkStatus(status: status)

        printDebug("setAuthenticationConfiguration: Authentication configuration set successfully")
    }
}

private extension KeychainPasswordManager {
    static func syncValue(_ synchronizable: Bool) -> CFBoolean {
        synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
    }

    func hashFrom(password: String) throws -> Data {
        let bytes = password.bytes
        let hashString = sodium.pwHash.str(passwd: bytes,
                                           opsLimit: sodium.pwHash.OpsLimitInteractive,
                                                 memLimit: sodium.pwHash.MemLimitInteractive)
        guard let hashed = hashString?.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        return hashed
    }
    
    func bytes(from string: String) throws -> [UInt8] {
        guard let passwordData = string.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        
        var bytes = [UInt8](repeating: 0, count: passwordData.count)
        passwordData.copyBytes(to: &bytes, count: string.count)
        return bytes
    }
    
    /// Persists the passcode type into the AuthenticationConfiguration. The
    /// deprecated standalone item (`encamera_passcode_type`) is no longer
    /// written — it remains only as a read fallback in
    /// `retrieveLegacyPasscodeTypeFromKeychain`.
    func savePasscodeTypeToKeychain(_ passcodeType: PasscodeType) throws {
        var config = getAuthenticationConfiguration() ?? AuthenticationConfiguration(enabledTypes: [])
        config.addAuthenticationType(.passcode(passcodeType))
        try setAuthenticationConfiguration(config: config)
    }
    
    func retrievePasscodeTypeFromKeychain() throws -> PasscodeType {
        if let type = getAuthenticationConfiguration()?.passcodeType {
            return type
        }
        return try retrieveLegacyPasscodeTypeFromKeychain()
    }

    /// Reads the deprecated standalone passcode-type item
    /// (`encamera_passcode_type`). New writes go into the
    /// AuthenticationConfiguration; this exists only as a read fallback until
    /// the type has been written there.
    func retrieveLegacyPasscodeTypeFromKeychain() throws -> PasscodeType {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.passcodeTypeKeyItem,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: syncQueryValueForReads
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        try KeychainManager.checkStatus(status: status)

        guard let data = item as? Data else {
            throw KeyManagerError.dataError
        }

        let decoder = JSONDecoder()
        return try decoder.decode(PasscodeType.self, from: data)
    }
}
