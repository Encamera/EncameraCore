//
//  KeychainBackupStatusManager.swift
//  EncameraCore
//

import Foundation
import Security

/// Owns the central backup status item: the always-synced record of whether
/// iCloud keychain backup is on, and which device last changed it.
///
/// Owned by `KeychainManager`, which decides when the flag is written.
struct KeychainBackupStatusManager: DebugPrintable {

    let keychainWrapper: KeychainWrapperProtocol

    /// The explicit state of the backup flag, `.notSet` when the item is
    /// absent or undecodable.
    func getBackupFlagState() -> KeychainBackupFlagState {
        guard let status = getBackupStatus() else { return .notSet }
        return status.enabled ? .enabled : .disabled
    }

    /// Reads and decodes the central backup status item. Both payload formats
    /// must stay readable forever: a device on an older app version can rewrite
    /// the legacy boolean at any time, and the item syncs.
    func getBackupStatus() -> KeychainBackupStatus? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                print("Warning: Found backup status flag but couldn't read its data.")
                return nil
            }
            return Self.decodeBackupStatus(from: data)
        case errSecItemNotFound:
            return nil
        default:
            print("Error reading backup status flag: \(determineOSStatus(status: status)). Assuming not set.")
            return nil
        }
    }

    /// Writes the always-synced central backup status flag. Extracted so the
    /// partial-failure path can rewrite it with the state the keychain items are
    /// *actually* in, rather than leaving it asserting the attempted state.
    func writeBackupFlag(enabled backupEnabled: Bool) throws {
        let backupStatusQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let statusPayload = try Self.encodeBackupStatus(KeychainBackupStatus(
            enabled: backupEnabled,
            deviceID: DeviceIDProvider.deviceID(),
            deviceName: DeviceIDProvider.deviceName(),
            timestamp: Date()
        ))

        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item
        let backupStatusAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.backupStatusKeyItem,
            kSecValueData as String: statusPayload,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        var status = keychainWrapper.secItemAdd(backupStatusAttributes as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let newAttributes: [String: Any] = [
                kSecValueData as String: statusPayload,
            ]
            status = keychainWrapper.secItemUpdate(backupStatusQuery as CFDictionary, newAttributes as CFDictionary)
        }

        printDebug("flip: backup flag write status \(status) (\(determineOSStatus(status: status)))")
        try KeychainManager.checkStatus(status: status)
    }

    static func decodeBackupStatus(from data: Data) -> KeychainBackupStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let status = try? decoder.decode(KeychainBackupStatus.self, from: data) {
            return status
        }
        // Legacy format: the flag was a raw Int-width boolean with no metadata.
        if let boolVal = data.boolValue {
            return KeychainBackupStatus(enabled: boolVal, deviceID: nil, deviceName: nil, timestamp: nil)
        }
        print("Warning: Found backup status flag but couldn't decode its value.")
        return nil
    }

    static func encodeBackupStatus(_ status: KeychainBackupStatus) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(status)
    }
}
