import Foundation
import Security

/// Concrete implementation of `KeychainWrapperProtocol` that calls the actual Security framework functions.
public class KeychainWrapper: KeychainWrapperProtocol {

    public init() {}

    public func secItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        return SecItemAdd(attributes, result)
    }

    public func secItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        return SecItemCopyMatching(query, result)
    }

    public func secItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        return SecItemUpdate(query, attributesToUpdate)
    }

    public func secItemDelete(_ query: CFDictionary) -> OSStatus {
        return SecItemDelete(query)
    }
} 
