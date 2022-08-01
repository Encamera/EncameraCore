//
//  MultipleKeyKeychainManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
import Sodium
import Combine

private enum KeychainConstants {
    static let applicationTag = "com.shadowpix.key"
    static let currentKey = "currentKey"
    static let account = "shadowpix"
    static let minKeyLength = 2
}


class MultipleKeyKeychainManager: ObservableObject, KeyManager {
    
    var isAuthorized: AnyPublisher<Bool, Never>
    private var authorized: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var sodium = Sodium()
    private var passwordValidator = PasswordValidator()
    private (set) var currentKey: ImageKey?  {
        didSet {
            keySubject.send(currentKey)
        }
    }
    var keyPublisher: AnyPublisher<ImageKey?, Never> {
        keySubject.eraseToAnyPublisher()
    }
    
    private var keySubject: PassthroughSubject<ImageKey?, Never> = .init()
    
    required init(isAuthorized: AnyPublisher<Bool, Never>) {
        self.isAuthorized = isAuthorized
        
        self.isAuthorized.sink { newValue in
            self.authorized = newValue
            if self.authorized == true {
                try? self.getActiveKeyAndSet()
            } else {
                self.currentKey = nil
            }
        }.store(in: &cancellables)

    }
    
    private func getActiveKeyAndSet() throws {
       
        let keyObject = try getActiveKey()
        
        currentKey = keyObject
    }
    
    func clearStoredKeys() throws {
        
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            throw KeyManagerError.deleteKeychainItemsFailed
        }
        currentKey = nil
        try setActiveKey(nil)
    }
    
    @discardableResult func generateNewKey(name: String) throws -> ImageKey {
        
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        guard name.count > KeychainConstants.minKeyLength else {
            throw KeyManagerError.keyNameError
        }
        
        let bytes = Sodium().secretStream.xchacha20poly1305.key()
        let key = ImageKey(name: name, keyBytes: bytes, creationDate: Date())
        try save(key: key)
        return key
    }
    
    func save(key: ImageKey) throws {
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
        if setNewKeyToCurrent {
            try setActiveKey(key.name)
        }

    }
    
    func storedKeys() throws -> [ImageKey] {
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
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
        let keys = keychainItems.compactMap { keychainItem -> ImageKey? in
            do {
                return try ImageKey(keychainItem: keychainItem)
            } catch {
                return nil
            }
        }.sorted(by: {
            $1.creationDate.compare($0.creationDate) == .orderedDescending
        })
        return keys
    }
    
    func deleteKey(_ key: ImageKey) throws {
        
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
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
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
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
    
    func getActiveKey() throws -> ImageKey {
        guard let activeKeyName = UserDefaults.standard.value(forKey: KeychainConstants.currentKey) as? String else {
            guard let firstStoredKey = try? storedKeys().first else {
                throw KeyManagerError.notFound
            }
            try setActiveKey(firstStoredKey.name)
            return firstStoredKey
        }
        return try getKey(by: activeKeyName)
    }
    
    func getKey(by keyName: KeyName) throws -> ImageKey {
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
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
        let key = try ImageKey(keychainItem: keychainItem)
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
        let bytes = try bytes(from: password)
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

private extension ImageKey {
    
    var keychainQueryDictForKeychain: [String: Any] {
        var query = keychainQueryDict
        query[kSecAttrApplicationLabel as String] = "\(KeychainConstants.applicationTag).\(name)"
        return query
    }
}
