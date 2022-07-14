//
//  KeyManager.swift
//  Shadowpix
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
    case notFound
    case dataError
    case keyExists
    case invalidPassword
}

protocol KeyManager {
    
    init(isAuthorized: AnyPublisher<Bool, Never>)
    
    var isAuthorized: AnyPublisher<Bool, Never> { get }
    var currentKey: ImageKey? { get }
    var keyPublisher: AnyPublisher<ImageKey?, Never> { get }
    func clearStoredKeys() throws
    func storedKeys() throws -> [ImageKey]
    func deleteKey(_ key: ImageKey) throws
    func setActiveKey(_ name: KeyName?) throws
    func save(key: ImageKey) throws
    @discardableResult func generateNewKey(name: String) throws-> ImageKey
    func checkPassword(_ password: String) throws -> Bool
    func setPassword(_ password: String) throws
    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation
    func changePassword(newPassword: String, existingPassword: String) throws
}
