//
//  VisitorSafetyState.swift
//  EncameraCore
//
//  Whether this device can delete originals from the Photos library, and
//  whether its key has a backup. Reported on the visitor profile every launch,
//  so a change made in iOS Settings or on another screen shows up without an
//  event.
//

import Foundation
import Photos

/// Access to the Photos library as the profile reports it. Deleting originals
/// needs `full`; import still works through the system picker otherwise.
public enum PhotoAccessLevel: String, CaseIterable, Sendable {
    case full
    case limited
    case denied
    case restricted
    case notAsked = "not_asked"

    public init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .full
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notAsked
        @unknown default: self = .denied
        }
    }

    /// The read/write level, the one deleting originals depends on.
    public static func current() -> PhotoAccessLevel {
        PhotoAccessLevel(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
}

/// One way this device's key is backed up. A device can have several at once;
/// none at all means no backup.
///
/// `icloud` is read from the keychain sync mode. The other two are actions the
/// user took on this device, recorded by `KeyBackupRecord`: neither the
/// clipboard nor the system password manager confirms that the phrase was
/// kept, so they mean "the user was handed the phrase", not "the phrase is
/// stored".
public enum KeyBackupState: String, CaseIterable, Sendable {
    case icloud
    case passwordManager = "password_manager"
    case phrase

    /// Every backup that applies: iCloud when sync is on, plus each recorded action.
    public static func resolve(isSyncEnabled: Bool, recorded: Set<KeyBackupRecord.Method>) -> Set<KeyBackupState> {
        var states = Set(recorded.map(\.state))
        if isSyncEnabled { states.insert(.icloud) }
        return states
    }

    /// Raw values in a fixed order, so equal sets always report the same array.
    public static func reportValue(_ states: Set<KeyBackupState>) -> [String] {
        states.map(\.rawValue).sorted()
    }
}

/// Device-local record of the key backup actions taken on this device.
///
/// Not tied to a particular key: the app keeps one key per account in normal
/// use, and a new device starts with an empty record.
public enum KeyBackupRecord {

    public enum Method: String, CaseIterable, Sendable {
        /// The phrase was copied, or entered to import or restore a key.
        case phrase
        /// A save of the phrase was submitted to the system password manager.
        case passwordManager = "password_manager"

        var state: KeyBackupState {
            switch self {
            case .phrase: return .phrase
            case .passwordManager: return .passwordManager
            }
        }
    }

    public static func note(_ method: Method) {
        var methods = recorded()
        guard methods.insert(method).inserted else { return }
        UserDefaultUtils.set(methods.map(\.rawValue).sorted(), forKey: .keyBackupMethodsRecorded)
    }

    public static func recorded() -> Set<Method> {
        let raw = UserDefaultUtils.value(forKey: .keyBackupMethodsRecorded) as? [String] ?? []
        return Set(raw.compactMap(Method.init(rawValue:)))
    }
}
