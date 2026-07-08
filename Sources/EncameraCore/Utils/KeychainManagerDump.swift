//
//  KeychainManagerDump.swift
//  Encamera
//
//  Debug keychain-inspector support split out of KeychainManager.
//

import Foundation
import Security // Need this import for keychain constants

/// One raw attribute of a keychain item, decoded into a human-readable string.
/// Used by the debug keychain inspector.
public struct KeychainDumpAttribute: Identifiable {
    public let id = UUID()
    /// Friendly name of the attribute (e.g. "Account"), falling back to the raw
    /// keychain key (e.g. "acct") when unknown.
    public let label: String
    /// The raw keychain attribute key (e.g. "acct", "v_Data", "sync").
    public let rawKey: String
    /// The value rendered for display.
    public let value: String
}

/// One keychain item and every attribute the keychain returned for it. Produced
/// by `dumpAllKeychainEntries()` for the debug inspector — a complete, widest-match
/// view of what the app has stored, including iCloud-synced copies.
public struct KeychainDumpEntry: Identifiable {
    public let id = UUID()
    /// Human-readable keychain class ("Generic Password", "Key", ...).
    public let itemClass: String
    /// Best-effort display name for the item (account, then label, then a placeholder).
    public let displayName: String
    /// Whether this specific copy of the item is marked to sync via iCloud Keychain.
    public let isSynchronizable: Bool
    /// Every attribute returned for the item, ordered for stable display.
    public let attributes: [KeychainDumpAttribute]
}

/// Read-only, structured dump of the app's keychain for the debug inspector.
/// Implemented once as a default on `KeychainManager` and vended through this
/// protocol so the inspector logic lives outside the main manager file.
public protocol KeychainDumping {
    func dumpAllKeychainEntries() -> [KeychainDumpEntry]
}

extension KeychainManager: KeychainDumping {}

extension KeychainDumping where Self: KeychainManager {

    /// Returns a structured, widest-match dump of every keychain item this app
    /// can see, across all item classes and including iCloud-synced copies
    /// (`kSecAttrSynchronizableAny`). Every attribute the keychain returns is
    /// decoded to a display string. Read-only — never mutates the keychain.
    /// Backs the debug Keychain Inspector view.
    public func dumpAllKeychainEntries() -> [KeychainDumpEntry] {
        let classes: [(secClass: CFString, name: String)] = [
            (kSecClassGenericPassword, "Generic Password"),
            (kSecClassInternetPassword, "Internet Password"),
            (kSecClassCertificate, "Certificate"),
            (kSecClassKey, "Key"),
            (kSecClassIdentity, "Identity")
        ]

        var entries: [KeychainDumpEntry] = []
        for entry in classes {
            let query: [String: Any] = [
                kSecClass as String: entry.secClass,
                kSecReturnData as String: true,
                kSecReturnAttributes as String: true,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]

            var result: CFTypeRef?
            let status = keychainWrapper.secItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                if status != errSecItemNotFound {
                    printDebug("dumpAllKeychainEntries: class \(entry.name) query failed with \(determineOSStatus(status: status))")
                }
                continue
            }

            let items = (result as? [[String: Any]]) ?? []
            for item in items {
                entries.append(makeDumpEntry(from: item, className: entry.name))
            }
        }
        return entries
    }

    private func makeDumpEntry(from item: [String: Any], className: String) -> KeychainDumpEntry {
        let attributes = item
            .map { KeychainDumpAttribute(label: Self.friendlyAttributeName(for: $0.key), rawKey: $0.key, value: Self.describeKeychainValue(key: $0.key, value: $0.value)) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        let account = item[kSecAttrAccount as String] as? String
        let label: String? = {
            if let string = item[kSecAttrLabel as String] as? String { return string }
            if let data = item[kSecAttrLabel as String] as? Data { return String(data: data, encoding: .utf8) }
            return nil
        }()
        let displayName = account ?? label ?? "(no account / label)"

        let syncValue = item[kSecAttrSynchronizable as String]
        let isSynchronizable = (syncValue as? Bool) ?? (syncValue as? NSNumber)?.boolValue ?? false

        return KeychainDumpEntry(itemClass: className, displayName: displayName, isSynchronizable: isSynchronizable, attributes: attributes)
    }

    /// Renders any keychain attribute value into a readable string: UTF-8 text
    /// when the bytes decode, otherwise a hex preview and byte count; sync flags
    /// as Yes/No; dates and numbers verbatim.
    private static func describeKeychainValue(key: String, value: Any) -> String {
        if key == (kSecAttrSynchronizable as String) {
            if let bool = value as? Bool { return bool ? "Yes" : "No" }
            if let num = value as? NSNumber { return num.boolValue ? "Yes" : "No" }
        }

        switch value {
        case let data as Data:
            if let string = String(data: data, encoding: .utf8), !string.isEmpty,
               string.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) {
                return "\(string)  (\(data.count) bytes)"
            }
            let hexPreview = data.prefix(32).map { String(format: "%02x", $0) }.joined()
            let ellipsis = data.count > 32 ? "…" : ""
            return "0x\(hexPreview)\(ellipsis)  (\(data.count) bytes)"
        case let date as Date:
            return "\(date)"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return "\(number)"
        case let string as String:
            return string
        default:
            return "\(value)"
        }
    }

    /// Maps raw keychain attribute keys (the short "acct"/"cdat" codes) to
    /// human-readable names. Unknown keys fall through to the raw key itself.
    private static func friendlyAttributeName(for rawKey: String) -> String {
        let mapping: [String: String] = [
            kSecClass as String: "Class",
            kSecAttrAccount as String: "Account",
            kSecAttrService as String: "Service",
            kSecAttrLabel as String: "Label",
            kSecAttrDescription as String: "Description",
            kSecAttrComment as String: "Comment",
            kSecAttrCreationDate as String: "Created",
            kSecAttrModificationDate as String: "Modified",
            kSecAttrAccessible as String: "Accessible",
            kSecAttrAccessGroup as String: "Access Group",
            kSecAttrSynchronizable as String: "iCloud Sync",
            kSecAttrApplicationTag as String: "Application Tag",
            kSecAttrApplicationLabel as String: "Application Label",
            kSecAttrKeyClass as String: "Key Class",
            kSecAttrKeyType as String: "Type",
            kSecAttrKeySizeInBits as String: "Key Size (bits)",
            kSecAttrEffectiveKeySize as String: "Effective Key Size",
            kSecAttrCreator as String: "Creator",
            kSecAttrGeneric as String: "Generic",
            kSecValueData as String: "Value Data",
            kSecAttrAccessControl as String: "Access Control"
        ]
        return mapping[rawKey] ?? rawKey
    }
}
