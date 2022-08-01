//
//  KeyManager.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Sodium
import Combine

enum KeyManagerError: Error {
    case deleteKeychainItemsFailed
    case unhandledError
    case notAuthorizedError
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
        case .notAuthorizedError:
            return "Not authorized for this operation."
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
    
    init(isAuthorized: AnyPublisher<Bool, Never>)
    
    var isAuthorized: AnyPublisher<Bool, Never> { get }
    var currentKey: ImageKey? { get }
    var keyPublisher: AnyPublisher<ImageKey?, Never> { get }
    func clearKeychainData() throws
    func storedKeys() throws -> [ImageKey]
    func deleteKey(_ key: ImageKey) throws
    func setActiveKey(_ name: KeyName?) throws
    func save(key: ImageKey) throws
    @discardableResult func generateNewKey(name: String) throws -> ImageKey
    func createBackupDocument() throws -> String
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String) throws
    func passwordExists() -> Bool
    func changePassword(newPassword: String, existingPassword: String) throws
}
