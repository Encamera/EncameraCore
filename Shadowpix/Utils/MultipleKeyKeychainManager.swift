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
}

class MultipleKeyKeychainManager: ObservableObject, KeyManager {
    
    var isAuthorized: AnyPublisher<Bool, Never>
    private var authorized: Bool = false
    private var cancellables = Set<AnyCancellable>()
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
                try? self.getKey()
            }
        }.store(in: &cancellables)

    }
    
    private func getKey() throws {
       
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
    }
    
    @discardableResult func generateNewKey(name: String) throws-> ImageKey {
        
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
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
            currentKey = key
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
            UserDefaults.standard.removeObject(forKey: KeychainConstants.currentKey)
            return
        }

        guard let key = try? getKey(by: name) else {
            throw KeyManagerError.notFound
        }
        UserDefaults.standard.set(key.name, forKey: KeychainConstants.currentKey)
        currentKey = key
    }
    
    func getActiveKey() throws -> ImageKey {
        guard let activeKeyName = UserDefaults.standard.value(forKey: KeychainConstants.currentKey) as? String else {
            throw KeyManagerError.notFound
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
}

private extension MultipleKeyKeychainManager {
    func checkStatus(status: OSStatus, defaultError: KeyManagerError = .unhandledError) throws {
        switch status {
        case errSecItemNotFound:
            throw KeyManagerError.notFound
        case errSecSuccess:
            break
        default:
            throw defaultError
        }
    }
}

private extension ImageKey {
    
    var keychainQueryDictForKeychain: [String: Any] {
        var query = keychainQueryDict
        query[kSecAttrApplicationLabel as String] = "\(KeychainConstants.applicationTag).\(name)"
        return query
    }
}
