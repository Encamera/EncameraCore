//
//  KeyManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Sodium

enum KeyManagerError: Error {
    case deleteKeychainItemsFailed
    case unhandledError
    case notAuthorizedError
    case notFound
    case dataError
}

protocol KeyManager {
    
    var isAuthorized: Bool { get }
    
    func getKey() throws -> ImageKey
    func clearStoredKeys() throws
    func generateNewKey(name: String) throws -> ImageKey
}

struct KeychainKeyManager: KeyManager {
    
    var isAuthorized: Bool = false
    
    func getKey() throws -> ImageKey {
        guard isAuthorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                    kSecAttrLabel as String: "currentKey",
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true,
                                    kSecReturnAttributes as String: true]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeyManagerError.notFound }
        guard status == errSecSuccess else { throw KeyManagerError.unhandledError }
        
        guard let existingItem = item as? [String : Any],
            let data = existingItem[kSecValueData as String] as? Data else {
                throw KeyManagerError.dataError
        }
        let keyObject = try JSONDecoder().decode(ImageKey.self, from: data)
        
        return keyObject

    }
    
    func clearStoredKeys() throws {
        
        guard isAuthorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "currentKey"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            throw KeyManagerError.deleteKeychainItemsFailed
        }
    }
    
    func generateNewKey(name: String) throws -> ImageKey {
        
        guard isAuthorized == true else {
            throw KeyManagerError.notAuthorizedError
        }
        
        let bytes = Sodium().secretStream.xchacha20poly1305.key()
        let key = ImageKey(name: name, keyBytes: bytes)
        let data = try JSONEncoder().encode(key)
        
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                    kSecAttrLabel as String: "currentKey",
                                    kSecValueData as String: data]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw
            KeyManagerError.unhandledError
        }
        return key

    }
    
}
