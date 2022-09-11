//
//  MultipleKeyKeychainManager.swift
//  Encamera
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
import Sodium
import Combine

private enum KeychainConstants {
    static let applicationTag = "com.encamera.key"
    static let currentKey = "currentKey"
    static let account = "encamera"
    static let minKeyLength = 2
}


class MultipleKeyKeychainManager: ObservableObject, KeyManager {
    
    var isAuthenticated: AnyPublisher<Bool, Never>
    private var authenticated: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var sodium = Sodium()
    private var passwordValidator = PasswordValidator()
    var keyDirectoryStorage: DataStorageSetting
    private (set) var currentKey: PrivateKey?  {
        didSet {
            keySubject.send(currentKey)
        }
    }
    var keyPublisher: AnyPublisher<PrivateKey?, Never> {
        keySubject.eraseToAnyPublisher()
    }
    
    private var keySubject: PassthroughSubject<PrivateKey?, Never> = .init()
    
    required init(isAuthenticated: AnyPublisher<Bool, Never>, keyDirectoryStorage: DataStorageSetting) {
        self.isAuthenticated = isAuthenticated
        self.keyDirectoryStorage = keyDirectoryStorage
        self.isAuthenticated.sink { newValue in
            self.authenticated = newValue
            do {
                if self.authenticated == true {
                    try self.getActiveKeyAndSet()
                } else {
                    try self.setActiveKey(nil)
                }
            } catch {
                debugPrint("Error getting/setting active key", error)
            }
        }.store(in: &cancellables)

    }
    
    private func getActiveKeyAndSet() throws {
       
        let keyObject = try getActiveKey()
        
        try setActiveKey(keyObject.name)
    }
    
    func clearKeychainData() throws {
        
        #if DEBUG
        #else
        guard authenticated == true else {
            throw KeyManagerError.notAuthenticatedError
        }
        #endif
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        try? checkStatus(status: status)
        
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword
        ]
        
        let passwordStatus = SecItemDelete(passwordQuery as CFDictionary)
        
        try? checkStatus(status: passwordStatus)
        try setActiveKey(nil)
        print("Keychain data cleared")
    }
    
    @discardableResult func generateNewKey(name: String, storageType: StorageType) throws -> PrivateKey {
        
        guard authenticated == true else {
            throw KeyManagerError.notAuthenticatedError
        }
        
        try validateKeyName(name: name)
        
        let bytes = Sodium().secretStream.xchacha20poly1305.key()
        let key = PrivateKey(name: name, keyBytes: bytes, creationDate: Date())
        try save(key: key, storageType: storageType)
        return key
    }
    
    func validateKeyName(name: String) throws {
        guard name.count > KeychainConstants.minKeyLength else {
            throw KeyManagerError.keyNameError
        }
    }
    
    func createBackupDocument() throws -> String {
        let keys = try storedKeys()
        
        return keys.map { key in
            return "Name: \(key.name)\nCode:\n\(key.base64String ?? "invalid")"
        }.joined(separator: "\n").appending("\n\nCopy the code into the \"Key Entry\" form in the app to use it again.")
    }
    
    func save(key: PrivateKey, storageType: StorageType) throws {
        var setNewKeyToCurrent: Bool
        do {
            let storedKeys = try storedKeys()
            setNewKeyToCurrent = storedKeys.count == 0
        } catch {
            setNewKeyToCurrent = true
        }
        let query = key.keychainQueryDictForKeychain
        let status = SecItemAdd(query as CFDictionary, nil)
        try checkStatus(status: status)
        keyDirectoryStorage.setStorageTypeFor(keyName: key.name, directoryModelType: storageType)

        if setNewKeyToCurrent {
            try setActiveKey(key.name)
        }
    }
    
    func storedKeys() throws -> [PrivateKey] {
        guard authenticated == true else {
            throw KeyManagerError.notAuthenticatedError
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try checkStatus(status: status)


        guard let keychainItems = item as? [[String: Any]] else {
            throw KeyManagerError.dataError
        }
        let keys = keychainItems.compactMap { keychainItem -> PrivateKey? in
            do {
                return try PrivateKey(keychainItem: keychainItem)
            } catch {
                return nil
            }
        }.sorted(by: {
            $1.creationDate.compare($0.creationDate) == .orderedDescending
        })
        return keys
    }
    
    func deleteKey(_ key: PrivateKey) throws {
        
        guard authenticated == true else {
            throw KeyManagerError.notAuthenticatedError
        }
        let key = try getKey(by: key.name)
        let query = key.keychainQueryDictForKeychain
        let status = SecItemDelete(query as CFDictionary)
        try checkStatus(status: status, defaultError: .deleteKeychainItemsFailed)
        if currentKey?.name == key.name {
            try setActiveKey(nil)
        }
    }
    
    func setActiveKey(_ name: KeyName?) throws {
        guard authenticated == true else {
            currentKey = nil
            throw KeyManagerError.notAuthenticatedError
        }
        guard let name = name else {
            currentKey = nil
            UserDefaults.standard.removeObject(forKey: KeychainConstants.currentKey)
            return
        }
        guard let key = try? getKey(by: name) else {
            throw KeyManagerError.notFound
        }
        currentKey = key
        UserDefaults.standard.set(key.name, forKey: KeychainConstants.currentKey)
    }
    
    func getActiveKey() throws -> PrivateKey {
        guard let activeKeyName = UserDefaults.standard.value(forKey: KeychainConstants.currentKey) as? String else {
            guard let firstStoredKey = try? storedKeys().first else {
                throw KeyManagerError.notFound
            }
            try setActiveKey(firstStoredKey.name)
            return firstStoredKey
        }
        return try getKey(by: activeKeyName)
    }
    
    func getKey(by keyName: KeyName) throws -> PrivateKey {
        guard authenticated == true else {
            throw KeyManagerError.notAuthenticatedError
        }
        
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true,
                                    kSecReturnAttributes as String: true,
                                    kSecAttrLabel as String: keyName]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try checkStatus(status: status)

        guard let keychainItem = item as? [String: Any]
               else {
            throw KeyManagerError.dataError
        }
        let key = try PrivateKey(keychainItem: keychainItem)
        return key

    }
    
    func passwordExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        do {
            try checkStatus(status: status)
        } catch is KeyManagerError {
            
        } catch {
            debugPrint("Key error", error)
        }
        return item != nil
    }
    
    func setPassword(_ password: String) throws {
        let hashed = try hashFrom(password: password)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecValueData as String: hashed
        ]
        let setPasswordStatus = SecItemAdd(query as CFDictionary, nil)
        
        try checkStatus(status: setPasswordStatus)
    }
    
    func changePassword(newPassword: String, existingPassword: String) throws {
        guard try checkPassword(existingPassword) == true else {
            throw KeyManagerError.invalidPassword
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        let deletePasswordStatus = SecItemDelete(query as CFDictionary)
        do {
            try checkStatus(status: deletePasswordStatus)
        } catch {
            debugPrint("Clearing password failed", error)
        }
        try setPassword(newPassword)
    }
    
    func checkPassword(_ password: String) throws -> Bool {
        guard passwordValidator.validate(password: password) == .valid else {
            throw KeyManagerError.invalidPassword
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainConstants.account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        do {
            try checkStatus(status: status)
            guard let item = item, let passwordData = item as? Data, let hashString = String(data: passwordData, encoding: .utf8) else {
                throw KeyManagerError.notFound
            }
            let passwordBytes = try bytes(from: password)
            return sodium.pwHash.strVerify(hash: hashString, passwd: passwordBytes)
        } catch {
            return false
        }
        
    }
    
    
}

private extension MultipleKeyKeychainManager {
    func checkStatus(status: OSStatus, defaultError: KeyManagerError = .unhandledError) throws {
        determineOSStatus(status: status)
        switch status {
        case errSecItemNotFound:
            throw KeyManagerError.notFound
        case errSecSuccess:
            break
        default:
            throw defaultError
        }
    }
    
    func hashFrom(password: String) throws -> Data {
        let bytes = password.bytes
        let hashString = sodium.pwHash.str(passwd: bytes,
                                           opsLimit: sodium.pwHash.OpsLimitInteractive,
                                                 memLimit: sodium.pwHash.MemLimitInteractive)
        guard let hashed = hashString?.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        return hashed
    }
    
    func bytes(from string: String) throws -> [UInt8] {
        guard let passwordData = string.data(using: .utf8) else {
            throw KeyManagerError.dataError
        }
        
        var bytes = [UInt8](repeating: 0, count: passwordData.count)
        passwordData.copyBytes(to: &bytes, count: string.count)
        return bytes
    }
}

private extension PrivateKey {
    
    var keychainQueryDictForKeychain: [String: Any] {
        var query = keychainQueryDict
        query[kSecAttrApplicationLabel as String] = "\(KeychainConstants.applicationTag).\(name)"
        return query
    }
}
