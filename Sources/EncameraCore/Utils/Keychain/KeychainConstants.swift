//
//  KeychainConstants.swift
//  Encamera
//

import Foundation

enum KeychainConstants {
    static let applicationTag = "com.encamera.key"
    static let account = "encamera"
    static let minKeyLength = 2
    static let passPhraseKeyItem = "encamera_key_passphrase"
    static let passcodeTypeKeyItem = "encamera_passcode_type"
    static let backupStatusKeyItem = "com.encamera.backupStatus"
    static let authenticationConfiguration = "com.encamera.authenticationConfiguration"
    static let multiDeviceState = "com.encamera.multiDeviceState"
    static let credentialResolutionMarker = "com.encamera.credentialResolved"
}
