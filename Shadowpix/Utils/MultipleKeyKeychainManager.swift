//
//  MultipleKeyKeychainManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
import Sodium
import Combine



class MultipleKeyKeychainManager: ObservableObject, KeyManager {
    
    var isAuthorized: AnyPublisher<Bool, Never>
    private var authorized: Bool = false
    private var cancellables = Set<AnyCancellable>()
    var currentKey: ImageKey! {
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
        var setNewKeyToCurrent: Bool
        do {
            let storedKeys = try storedKeys()
            setNewKeyToCurrent = storedKeys.count == 0
        } catch {
            setNewKeyToCurrent = true
        }
        let query = key.keychainQueryDict
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyManagerError.unhandledError
        }
        if setNewKeyToCurrent {
            currentKey = key
        }
        return key
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
        guard status == errSecSuccess else {
            throw KeyManagerError.unhandledError
        }

        guard let keychainItems = item as? [[String: Any]] else {
            throw KeyManagerError.dataError
        }
        let keys = try keychainItems.map { keychainItem -> ImageKey in
            do {
                return try ImageKey(keychainItem: keychainItem)
            } catch {
                throw KeyManagerError.dataError
            }
        }.sorted(by: {
            $1.creationDate.compare($0.creationDate) == .orderedDescending
        })
        return keys
    }
    
    func deleteKey(by name: KeyName) throws {
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        let key = try getKey(by: name)
        let query = key.keychainQueryDict
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            throw KeyManagerError.deleteKeychainItemsFailed
        }
        if currentKey.name == key.name {
            currentKey = nil
        }
    }
    
    func setActiveKey(_ name: KeyName) throws {
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        UserDefaults.standard.set(name, forKey: "currentKey")
        currentKey = try getActiveKey()
    }
    
    func getActiveKey() throws -> ImageKey {
        guard let activeKeyName = UserDefaults.standard.value(forKey: "currentKey") as? String else {
            throw KeyManagerError.notFound
        }
        return try getKey(by: activeKeyName)
    }
    
    func getKey(by keyName: KeyName) throws -> ImageKey {
        guard authorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        let keychainKeyName = ImageKey.keychainNameEntry(keyName: keyName)
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true,
                                    kSecReturnAttributes as String: true,
                                    kSecAttrApplicationTag as String: keychainKeyName]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeyManagerError.notFound }
        guard status == errSecSuccess else { throw KeyManagerError.unhandledError }
        guard let keychainItem = item as? [String: Any]
               else {
            throw KeyManagerError.dataError
        }
        let key = try ImageKey(keychainItem: keychainItem)
        return key

    }
}
