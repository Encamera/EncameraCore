//
//  KeychainCredentialSnapshot.swift
//  Encamera
//

import Foundation

/// State of the central iCloud-backup flag item (account `com.encamera.backupStatus`).
/// `.notSet` means the flag item hasn't been written on this device yet — or, on a
/// fresh second device, hasn't arrived via iCloud Keychain yet.
public enum KeychainBackupFlagState {
    case enabled, disabled, notSet
}

/// Payload of the central iCloud-backup flag item, recording which device
/// flipped the switch and when. The item itself is always synchronizable, so
/// this object propagates to all devices — a second device that finds its key
/// material deleted can tell the user where the flip came from.
///
/// Metadata fields are nil for items migrated from the legacy boolean format,
/// where the flipping device was never recorded.
public struct KeychainBackupStatus: Codable, Equatable {
    public let enabled: Bool
    public let deviceID: String?
    public let deviceName: String?
    public let timestamp: Date?

    /// True when the flip was recorded by a device other than this one.
    public var flippedByOtherDevice: Bool {
        guard let deviceID else { return false }
        return deviceID != DeviceIDProvider.deviceID()
    }

    public init(enabled: Bool, deviceID: String?, deviceName: String?, timestamp: Date?) {
        self.enabled = enabled
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = timestamp
    }
}

/// Point-in-time view of which credential items are present in the keychain,
/// queried with kSecAttrSynchronizableAny so items that arrived via iCloud
/// Keychain are counted regardless of the local backup-flag state. Used to
/// poll for iCloud Keychain arrival on a fresh install — there is no system
/// notification for it.
public struct KeychainCredentialSnapshot: Equatable {
    public let passwordExists: Bool
    public let passphraseExists: Bool
    public let defaultKeyExists: Bool
    public let biometricsEnabled: Bool
    public let backupFlagState: KeychainBackupFlagState
    /// Full flag payload with flip metadata; nil when the item is absent.
    public let backupStatus: KeychainBackupStatus?

    public var hasAccessCredential: Bool {
        passwordExists || biometricsEnabled
    }

    public var hasAnyCredential: Bool {
        passwordExists || passphraseExists || defaultKeyExists || biometricsEnabled
    }

    public init(
        passwordExists: Bool,
        passphraseExists: Bool,
        defaultKeyExists: Bool,
        biometricsEnabled: Bool,
        backupFlagState: KeychainBackupFlagState,
        backupStatus: KeychainBackupStatus? = nil
    ) {
        self.passwordExists = passwordExists
        self.passphraseExists = passphraseExists
        self.defaultKeyExists = defaultKeyExists
        self.biometricsEnabled = biometricsEnabled
        self.backupFlagState = backupFlagState
        self.backupStatus = backupStatus
    }
}

extension KeychainCredentialSnapshot: CustomStringConvertible {
    public var description: String {
        "[password=\(passwordExists), passphrase=\(passphraseExists), defaultKey=\(defaultKeyExists), backupFlag=\(backupFlagState)]"
    }
}
