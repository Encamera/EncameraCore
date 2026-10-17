//
//  KeyManager.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Sodium
import Combine

public enum KeyManagerError: ErrorDescribable {
    case unhandledError(String)
    case notFound
    case dataError
    case keyExists
    case invalidPassword
    case invalidInput
    case invalidPassphraseData
    case keyDerivationFailed
    case dictionaryLoadError
    case dictionaryTooSmall
    case keyUpdateFailed
    case keyDeletionFailed
    /// `backupKeychainToiCloud` could not put every credential item into the
    /// requested sync state. `actual` is the state the items were observed to
    /// be in afterwards, which is what the UI must show — never `attempted`.
    case syncFlipFailed(attempted: Bool, actual: Bool, details: String)
    public var displayDescription: String {
        switch self {
        case .unhandledError(let error):
            return "Unhandled error: \(error)"
        case .notFound:
            return L10n.keyNotFound
        case .dataError:
            return L10n.errorCodingKeychainData
        case .keyExists:
            return L10n.aKeyWithThisNameAlreadyExists
        case .invalidPassword:
            return L10n.invalidPassword
        case .invalidInput:
            return "Invalid input"
        case .invalidPassphraseData:
            return "Invalid passphrase data"
        case .keyDerivationFailed:
            return "Key derivation failed"
        case .dictionaryLoadError:
            return "Could not load dictionary"
        case .dictionaryTooSmall:
            return "Dictionary too small"
        case .keyUpdateFailed:
            return "Key update failed"
        case .keyDeletionFailed:
            return "Key deletion failed"
        case .syncFlipFailed:
            return L10n.Settings.ICloudBackupAndSync.flipFailed
        }

    }
    
}

extension KeyManagerError: Equatable {
    public static func ==(lhs: KeyManagerError, rhs: KeyManagerError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound),
             (.dataError, .dataError),
             (.keyExists, .keyExists),
             (.invalidPassword, .invalidPassword),
             (.invalidInput, .invalidInput),
             (.keyDerivationFailed, .keyDerivationFailed),
             (.dictionaryLoadError, .dictionaryLoadError),
             (.dictionaryTooSmall, .dictionaryTooSmall),
             (.keyUpdateFailed, .keyUpdateFailed),
             (.keyDeletionFailed, .keyDeletionFailed):
            return true
        case (.unhandledError(let lhsError), .unhandledError(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}


/// How far a key deletion reaches.
///
/// Deleting a `kSecAttrSynchronizable` item tombstones it and the deletion
/// propagates to every device on the iCloud account. That is almost never what
/// a user resetting *one* device expects, so account-wide is opt-in and callers
/// have to say so explicitly.
public enum KeyDeletionScope {
    /// Removes only this device's non-synchronizable copy. Other devices keep
    /// theirs, and a synced copy can flow back.
    case deviceLocal
    /// Removes the key everywhere on the account, synced copies included.
    case accountWide
}

public protocol KeyManager {

    var isSyncEnabled: Bool { get }
    var isAuthenticated: AnyPublisher<Bool, Never> { get }
    var currentKey: PrivateKey? { get }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> { get }
    var passcodeType: PasscodeType { get }

    init(isAuthenticated: AnyPublisher<Bool, Never>, keychainWrapper: KeychainWrapperProtocol)

    /// Wipes this app's keychain footprint.
    ///
    /// There is deliberately no default value here: account-wide erasure is
    /// unrecoverable, so a caller has to name the scope it means. The no-argument
    /// `clearKeychainData()` convenience below resolves to `.deviceLocal`.
    func clearKeychainData(scope: KeyDeletionScope)
    /// Every Encamera-owned keychain item still readable from this device, across
    /// all item classes and INCLUDING iCloud-synced copies, as `"<class>|<name>"`.
    ///
    /// Exists so an erase can be verified rather than assumed. After an
    /// account-wide sweep this must be empty; anything left is residue the user was
    /// told had been destroyed.
    ///
    /// What this can and cannot prove about tombstones: Security.framework exposes
    /// no tombstone API, so the only local evidence available is that a
    /// widest-match query (`kSecAttrSynchronizableAny`) no longer returns the item.
    func residualKeychainItemNames() -> [String]
    @MainActor
    func keyWith(uuid: UUID) -> PrivateKey?
    func storedKeys() throws -> [PrivateKey]
    /// Removes a single key from the library, addressed by fingerprint.
    /// Defaults to device-local; see `KeyDeletionScope`.
    func deleteKey(fingerprint: String, scope: KeyDeletionScope) throws
    func getPasswordHash() throws -> Data
    func setPasswordHash(hash: Data) throws
    func save(key: PrivateKey, setNewKeyToCurrent: Bool) throws
    func generateKeyUsingRandomWords() throws -> PrivateKey
    @discardableResult func generateKeyFromPasswordComponentsAndSave(_ components: [String]) throws -> PrivateKey
    @discardableResult func saveKeyWithPassphrase(passphrase: KeyPassphrase) throws -> PrivateKey
    @discardableResult func restoreDefaultKeyFromPassphraseIfNeeded() throws -> Bool
    func retrieveKeyPassphrases() throws -> [KeyPassphrase]
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String, type: PasscodeType) throws
    func setOrUpdatePassword(_ password: String, type: PasscodeType) throws
    func passwordExists() -> Bool
    func hasResolvedCredentialsBefore() -> Bool
    @discardableResult func setResolvedCredentialsBefore() -> Bool
    func credentialSnapshot() -> KeychainCredentialSnapshot
    func changePassword(newPassword: String, existingPassword: String, type: PasscodeType) throws
    func setiCloudKeychainSyncEnabled(enabled: Bool) throws
    /// Starts watching the always-synced backup flag and adopting the
    /// account's credentials when another device turns backup on. The toggle
    /// above only flips the items on the device it is tapped on; this is the
    /// other side. See `KeychainSyncManager`.
    func startKeychainSyncMonitor()
    func stopKeychainSyncMonitor()
    func clearPassword() throws
    func dumpAllKeychainEntries() -> [KeychainDumpEntry]
    func getAuthenticationConfiguration() -> AuthenticationConfiguration?
    func setAuthenticationConfiguration(config: AuthenticationConfiguration) throws
    /// The always-synced multi-device state record; `nil` until some device writes it.
    func getMultiDeviceState() -> MultiDeviceState?
    /// Merges into the stored record rather than replacing it, so concurrent
    /// writers don't drop each other's device entries.
    func setMultiDeviceState(_ state: MultiDeviceState) throws
    /// Replaces the stored record WITHOUT the merge that `setMultiDeviceState`
    /// applies. The destructive delete-my-iCloud-data path needs this to
    /// clear the fingerprints while carrying the existing device roster over — the
    /// merge unions fingerprints, so it can never shrink the list. This is an
    /// update, not a delete: the item stays synchronizable, so nothing is
    /// tombstoned. Use `setMultiDeviceState` for every additive write; this is
    /// only for the deliberate reset.
    func overwriteMultiDeviceState(_ state: MultiDeviceState) throws
}

public extension KeyManager {
    /// Resets this device only. The safe default: nothing is tombstoned, so the
    /// user's other devices keep their keys, passphrase and password hash.
    func clearKeychainData() {
        clearKeychainData(scope: .deviceLocal)
    }

}
