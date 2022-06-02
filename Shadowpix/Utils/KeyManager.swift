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
}

protocol KeyManager {
    
    var isAuthorized: AnyPublisher<Bool, Never> { get }
    var currentKey: ImageKey? { get set }
    var keyPublisher: AnyPublisher<ImageKey?, Never> { get }
    func clearStoredKeys() throws
    func generateNewKey(name: String) throws -> ImageKey
}

class KeychainKeyManager: ObservableObject, KeyManager {
    
    var isAuthorized: AnyPublisher<Bool, Never>
    private var authorized: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    var currentKey: ImageKey?
    var keyPublisher: AnyPublisher<ImageKey?, Never> {
        keySubject.eraseToAnyPublisher()
    }
    
    private var keySubject: PassthroughSubject<ImageKey?, Never> = .init()
    
    init(isAuthorized: AnyPublisher<Bool, Never>) {
        self.isAuthorized = isAuthorized
        
        self.isAuthorized.sink { newValue in
            self.authorized = newValue
            self.keySubject.send(try? self.getKey())
        }.store(in: &cancellables)
        
        self.keySubject.sink { key in
            self.currentKey = key
        }.store(in: &cancellables)
        
    }
    
    private func getKey() throws -> ImageKey {
        guard authorized == true else {
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
        
        guard authorized == true else {
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
        
        guard authorized == true else {
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
