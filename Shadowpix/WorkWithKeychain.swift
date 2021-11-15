//
//  WorkWithKeychain.swift
//  sNotes
//
//  Created by Sergey Sedov on 25.05.2021.
//  Copyright © 2021 Apple. All rights reserved.
//

import Foundation

enum KeychainError: Error {
    case keychainItemNotFound
    case unexpectedPasswordData
    case unhandledError(status: OSStatus)
}

class WorkWithKeychain {
        
    enum keyKeychain: String {
        case account = "sNotes"
        case passcode = "passCode"
        case key = "symKey"
        
        case number = "number"
        case cvc = "cvc"
        case pin = "pin"
        
        case password = "password"

    }
    
    
    //MARK: - Passcode
    //Return true if the code is in the keychain
    static public func isPasscode() -> Bool {
        return keychainCheck(service: keyKeychain.passcode.rawValue)
    }
    
    static public func checkPassCode(passCode: String) -> Bool {
        passCode.caseInsensitiveCompare(getPassCode()) == .orderedSame
    }
    
    //return personal code
    static private func getPassCode() -> String {
        let data = read(service: keyKeychain.passcode.rawValue)
        let pc = String(data: data!, encoding: .utf8)
        return pc!
    }
    
    //save personal code
    static public func setPassCode(passCode: String) {
        let data = passCode.data(using: .utf8)!
        write(service: keyKeychain.passcode.rawValue, data: data)
    }
    
    
    //MARK: - Card info
    //Return true if the code is in the keychain
    static public func isKeychain(service: String) -> Bool {
        return keychainCheck(service: service)
    }
    
    //return Number info
    static public func getService(key: keyKeychain, addService: String) -> String? {
        let service = key.rawValue + addService
        
        guard let data = read(service: service) else {
            return nil
        }
        let info = String(data: data, encoding: .utf8)
        return info
    }
    
    //save Number info
    static public func setService(key: keyKeychain, addService: String, data: String) {
        let service = key.rawValue + addService
        let data = data.data(using: .utf8)!
        write(service: service, data: data)
    }
    
    //MARK: - Key
    //Return true if the key is in the keychain
    static public func isKey() -> Bool {
        return keychainCheck(service: keyKeychain.key.rawValue)
    }
    
    static public func getKeyObject() -> ImageKey? {
        guard let keyData = read(service: keyKeychain.key.rawValue),
              let keyObject = try? JSONDecoder().decode(ImageKey.self, from: keyData) else {
            return nil
        }
        
        return keyObject
    }
        
    //return key
    static public func getKey() -> Data? {
        
        guard let keyObject = getKeyObject() else {
            return nil
        }
        
        return keyObject.keyData
    }
    
    static public func getKeyString() -> String? {
        return read(service: keyKeychain.key.rawValue)?.base64EncodedString()
    }
    
    //save key
    static public func setKey(key: ImageKey) {
        clearKeychain()
        do {
            let data = try JSONEncoder().encode(key)
            write(service: keyKeychain.key.rawValue, data: data)
            ShadowPixState.shared.selectedKey = key
        } catch {
            fatalError("Could not set key in keychain")
        }
    }

        
    
    // MARK: - Work with Keychein
    // MARK: - check
    //checks for data in the keychain
    //returns true - if there is data
    static private func keychainCheck(service: String) -> Bool {
        if read(service: service) == nil {
            return false
        } else {
            return true
        }
    }
    // MARK: - reed
    static private func read(service: String) -> Data? {
        do {
            let t = try readKeychain(service: service)
            return (t as! Data)
        } catch  {
            print("Error read, service:", service, error)
            return nil
        }
    }
    
    static private func readKeychain(service: String) throws -> Any? {
        
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keyKeychain.account.rawValue,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecReturnData as String: true,
                                    kSecReturnAttributes as String: true]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.keychainItemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unhandledError(status: status) }
        
        guard let existingItem = item as? [String : Any],
            let data = existingItem[kSecValueData as String] as? Data
            else {
                throw KeychainError.unexpectedPasswordData
        }
        return data
    }
    
    // MARK: - write
    static private func write(service: String, data: Data) {
        do {
            let _ = try setKeychain(service: service, data: data)
        } catch  {
            fatalError("Error write, service=\(String(describing: service))")
        }
    }
    
    static private func setKeychain(service: String, data: Data) throws -> Any? {
        
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keyKeychain.account.rawValue,
                                    kSecAttrService as String: service,
                                    kSecValueData as String: data]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw
                KeychainError.unhandledError(status: status)
        }
        return status
    }
    
    // MARK: - update
    static private func updateKeychain(service: String, data: Data) {
        
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keyKeychain.account.rawValue,
                                    kSecAttrService as String: service,
                                    kSecValueData as String: data]
        
        let attributesToUpdate: [String: Any] = [kSecAttrAccount as String: keyKeychain.account.rawValue,
                                                 kSecAttrService as String: service,
                                                 kSecValueData as String: data]
        
        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status != errSecSuccess {
            print("updateKeychain error, service=",service)
        } else {
            print("updateKeychain OK, service=",service)
        }
    }
    
    // MARK: - clear
    static public func clearKeychain() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keyKeychain.account.rawValue]
        let status = SecItemDelete(query as CFDictionary)
        
        if status != errSecSuccess {
            print("clearKeychain ERROR")
        } else {
            print("clearKeychain OK")
        }
    }
}
