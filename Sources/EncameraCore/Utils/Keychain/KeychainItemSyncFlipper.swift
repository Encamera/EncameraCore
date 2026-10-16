//
//  KeychainItemSyncFlipper.swift
//  EncameraCore
//

import Foundation
import Security

/// Moves a single keychain item on or off the iCloud keychain. Shared by the
/// managers that own synchronizable items, so every flip goes through the same
/// write-then-delete sequence.
struct KeychainItemSyncFlipper: DebugPrintable {

    let keychainWrapper: KeychainWrapperProtocol

    /// Leaves exactly one copy of the matched item behind, carrying the data
    /// that was in use, marked `synchronizable == enabled`.
    ///
    /// It cannot be done with a single `SecItemUpdate`. Once a device holds
    /// both a local and an iCloud-delivered copy of an item — the normal state
    /// of any second device — an update that would collapse the two onto one
    /// sync value collides, and the keychain refuses it with
    /// `errSecDuplicateItem` without changing anything. That refusal, swallowed
    /// by the toggle, is why key backup could not be turned off.
    /// `KeychainSyncFlipPlatformContractTests` pins the behavior against the
    /// real Security framework.
    ///
    /// So: write the target copy FIRST, then delete the other. Never the
    /// reverse — a delete-then-add that is interrupted (backgrounded, killed,
    /// device locked) between the two steps would destroy the only copy of the
    /// user's key and with it every encrypted file.
    ///
    /// Deleting the synchronizable copy is what takes the secret off iCloud:
    /// the deletion propagates, so the other devices drop their copies too.
    /// That is precisely what turning key backup off means.
    func setSynchronizable(_ enabled: Bool,
                           forItemMatching baseQuery: [String: Any],
                           description: String) throws {
        let copies = try readCopies(matching: baseQuery)
        guard !copies.isEmpty else {
            return
        }

        let copiesInTargetState = copies.filter { boolTypedSyncFlag(of: $0) == enabled }

        if copies.count == 1 && copiesInTargetState.count == 1 {
            return
        }

        let winner = copies.first { boolTypedSyncFlag(of: $0) != enabled } ?? copies[0]
        guard let winningData = winner[kSecValueData as String] as? Data else {
            throw KeyManagerError.dataError
        }

        // 1. Make sure a copy with the target flag exists, holding those bytes.
        if copiesInTargetState.isEmpty {
            try addCopy(of: winner, data: winningData, matching: baseQuery, synchronizable: enabled)
        } else {
            try updateCopy(matching: baseQuery, synchronizable: enabled, data: winningData)
        }

        // 2. Drop the copies on the other side. Only now is it safe.
        try deleteCopies(matching: baseQuery, synchronizable: !enabled)

        printDebug("Set \(description) synchronizable=\(enabled)")
    }

    /// Flips each generic-password item in `credentials` independently,
    /// returning a failure line per item that could not be flipped.
    func setSynchronizable(_ enabled: Bool,
                           genericCredentials credentials: [(account: String, description: String)]) -> [String] {
        var failures: [String] = []
        for credential in credentials {
            do {
                try setSynchronizable(enabled, forItemMatching: [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: credential.account
                ], description: credential.description)
            } catch {
                printDebug("flip: \(credential.description) FAILED:", error)
                failures.append("\(credential.description): \(error)")
            }
        }
        return failures
    }
}

private extension KeychainItemSyncFlipper {

    /// Every copy of the matched item, local and synchronizable, with data and
    /// attributes. Empty when there is none.
    func readCopies(matching baseQuery: [String: Any]) throws -> [[String: Any]] {
        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecReturnAttributes as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        readQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let readStatus = keychainWrapper.secItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecItemNotFound {
            return []
        }
        try KeychainManager.checkStatus(status: readStatus)
        return result as? [[String: Any]] ?? []
    }

    /// Adds a copy of `winner` carrying `data`, with the given sync flag. The
    /// creation date and key identity attributes are carried over so the new
    /// copy sorts and matches like the one it replaces.
    func addCopy(of winner: [String: Any],
                 data: Data,
                 matching baseQuery: [String: Any],
                 synchronizable: Bool) throws {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        addQuery[kSecAttrSynchronizable as String] = Self.syncValue(synchronizable)
        if let creationDate = winner[kSecAttrCreationDate as String] {
            addQuery[kSecAttrCreationDate as String] = creationDate
        }
        if let applicationLabel = winner[kSecAttrApplicationLabel as String] {
            addQuery[kSecAttrApplicationLabel as String] = applicationLabel
        }
        if let applicationTag = winner[kSecAttrApplicationTag as String] {
            addQuery[kSecAttrApplicationTag as String] = applicationTag
        }
        try KeychainManager.checkStatus(status: keychainWrapper.secItemAdd(addQuery as CFDictionary, nil))
    }

    /// Overwrites the existing copy with the given sync flag with `data`.
    func updateCopy(matching baseQuery: [String: Any],
                    synchronizable: Bool,
                    data: Data) throws {
        var updateQuery = baseQuery
        updateQuery[kSecAttrSynchronizable as String] = Self.syncValue(synchronizable)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        try KeychainManager.checkStatus(status: keychainWrapper.secItemUpdate(updateQuery as CFDictionary,
                                                              attributes as CFDictionary))
    }

    /// Deletes every copy with the given sync flag. Deleting the synchronizable
    /// copy propagates, so it also leaves the account's other devices.
    func deleteCopies(matching baseQuery: [String: Any], synchronizable: Bool) throws {
        var deleteQuery = baseQuery
        deleteQuery[kSecAttrSynchronizable as String] = Self.syncValue(synchronizable)
        let deleteStatus = keychainWrapper.secItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecItemNotFound {
            try KeychainManager.checkStatus(status: deleteStatus)
        }
    }

    static func syncValue(_ synchronizable: Bool) -> CFBoolean {
        synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
    }

    func boolTypedSyncFlag(of attributes: [String: Any]) -> Bool {
        let value = attributes[kSecAttrSynchronizable as String]
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
