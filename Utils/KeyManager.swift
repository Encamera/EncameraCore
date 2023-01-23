//
//  KeyManager.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Sodium
import Combine

enum KeyManagerError: ErrorDescribable {
    case deleteKeychainItemsFailed
    case unhandledError
    case notAuthenticatedError
    case keyNameError
    case notFound
    case dataError
    case keyExists
    case invalidPassword
    
    var displayDescription: String {
        switch self {
        case .deleteKeychainItemsFailed:
            return "Could not delete keychain items."
        case .unhandledError:
            return "Unhandled error."
        case .notAuthenticatedError:
            return "Not authenticated for this operation."
        case .keyNameError:
            return "Key name is invalid, must be more than two characters"
        case .notFound:
            return "Key not found."
        case .dataError:
            return "Error coding keychain data."
        case .keyExists:
            return "A key with this name already exists."
        case .invalidPassword:
            return "Invalid password."
        }
    }
    
}

protocol KeyManager {
    
    init(isAuthenticated: AnyPublisher<Bool, Never>, keyDirectoryStorage: DataStorageSetting)
    
    var isAuthenticated: AnyPublisher<Bool, Never> { get }
    var currentKey: PrivateKey? { get }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> { get }
    var keyDirectoryStorage: DataStorageSetting { get }
    func clearKeychainData()
    func storedKeys() throws -> [PrivateKey]
    func deleteKey(_ key: PrivateKey) throws
    func setActiveKey(_ name: KeyName?) throws
    func save(key: PrivateKey, storageType: StorageType, setNewKeyToCurrent: Bool) throws
    @discardableResult func generateNewKey(name: String, storageType: StorageType) throws -> PrivateKey
    func validateKeyName(name: String) throws
    func createBackupDocument() throws -> String
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String) throws
    func passwordExists() -> Bool
    func changePassword(newPassword: String, existingPassword: String) throws
}
