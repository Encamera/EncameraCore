//
//  KeychainConstants.swift
//  Encamera
//

import Foundation

enum KeychainConstants {
    static let applicationTag = "com.encamera.key"
    /// The tag written on every key item. Builds that still carry a key name
    /// read it back from the tag's suffix and look the key up as
    /// `AppConstants.legacyDefaultKeyName`, so a device on such a build sharing
    /// this iCloud keychain keeps finding its key.
    static let keyApplicationTag = "\(applicationTag).\(AppConstants.legacyDefaultKeyName)"
    static let account = "encamera"
    static let passPhraseKeyItem = "encamera_key_passphrase"
    /// Service shared by the per-key passphrase items, whose account is the
    /// key's fingerprint.
    static let passPhraseService = "com.encamera.keyPassphrase"
    static let passcodeTypeKeyItem = "encamera_passcode_type"
    static let backupStatusKeyItem = "com.encamera.backupStatus"
    static let authenticationConfiguration = "com.encamera.authenticationConfiguration"
    static let multiDeviceState = "com.encamera.multiDeviceState"
    static let credentialResolutionMarker = "com.encamera.credentialResolved"
}
