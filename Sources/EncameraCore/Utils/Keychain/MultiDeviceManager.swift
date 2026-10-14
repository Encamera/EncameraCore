//
//  MultiDeviceManager.swift
//  EncameraCore
//

import Foundation
import Security

/// Reads and writes the always-synced `MultiDeviceState` keychain record.
///
/// Owned by `KeychainManager`, which forwards the `KeyManager` multi-device
/// calls here.
struct MultiDeviceManager: DebugPrintable {

    let keychainWrapper: KeychainWrapperProtocol

    /// Reads the always-synced multi-device state record. `nil` means no device
    /// on this account has written it yet (or it hasn't arrived from iCloud).
    ///
    /// Queried with `kSecAttrSynchronizableAny` so it is found regardless of the
    /// stored item's sync flag, matching `getAuthenticationConfiguration`.
    func getState() -> MultiDeviceState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                printDebug("getMultiDeviceState: query failed with status \(status) (\(determineOSStatus(status: status)))")
            }
            return nil
        }

        guard let data = item as? Data,
              let state = try? JSONDecoder().decode(MultiDeviceState.self, from: data) else {
            printDebug("getMultiDeviceState: Could not decode multi-device state")
            return nil
        }

        return state
    }

    /// Merges `state` into the stored multi-device state record and writes it back.
    ///
    /// Merging rather than replacing means a device appending itself to the
    /// roster can't drop another device that appeared since it last read.
    /// See `MultiDeviceState.merging(existing:incoming:)`.
    func setState(_ state: MultiDeviceState) throws {
        let merged = MultiDeviceState.merging(existing: getState(), incoming: state)
        try writeRecord(merged)
    }

    /// Replaces the record with exactly `state`, bypassing the merge, so the
    /// destructive path can clear the fingerprints while keeping the
    /// roster the caller carried over. Still an update (never a delete), so the
    /// synchronizable item is not tombstoned.
    func overwriteState(_ state: MultiDeviceState) throws {
        try writeRecord(state)
    }

    /// Deletes the record from this device and, because it is synchronizable,
    /// from every other device on the account.
    func deleteState() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = keychainWrapper.secItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Failed to delete multi-device state item: \(status)")
        }
    }
}

private extension MultiDeviceManager {

    /// The raw synchronizable write shared by the merging setter and the
    /// non-merging overwrite. Adds the item, or updates its value data in place if
    /// it already exists — never deletes it, so no cross-device tombstone.
    func writeRecord(_ state: MultiDeviceState) throws {
        guard let encoded = try? JSONEncoder().encode(state) else {
            printDebug("setMultiDeviceState: Could not encode multi-device state")
            throw KeyManagerError.dataError
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        // NOTE: kSecAttrSynchronizable is ALWAYS true for this item — it must
        // reach every device on the account regardless of the backup toggle.
        // That is why nothing secret may ever enter MultiDeviceState.
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.multiDeviceState,
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

        printDebug("setMultiDeviceState: Multi-device state set successfully")
    }
}
