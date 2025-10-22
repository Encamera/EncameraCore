import Foundation
import Security

/// A protocol abstracting the Keychain SecItem* functions for testability.
public protocol KeychainWrapperProtocol {
    /// Wraps the `SecItemAdd` function.
    /// - Parameters:
    ///   - attributes: The attributes dictionary for the new item.
    ///   - result: On return, a reference to the newly added item. Pass nil if you do not need this.
    /// - Returns: An `OSStatus` code indicating success or failure.
    func secItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    /// Wraps the `SecItemCopyMatching` function.
    /// - Parameters:
    ///   - query: The query dictionary specifying the items to search for.
    ///   - result: On return, a reference to the found item(s).
    /// - Returns: An `OSStatus` code indicating success or failure (e.g., `errSecItemNotFound`).
    func secItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    /// Wraps the `SecItemUpdate` function.
    /// - Parameters:
    ///   - query: The query dictionary specifying the item(s) to update.
    ///   - attributesToUpdate: The attributes dictionary containing the updates.
    /// - Returns: An `OSStatus` code indicating success or failure.
    func secItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus

    /// Wraps the `SecItemDelete` function.
    /// - Parameters:
    ///   - query: The query dictionary specifying the item(s) to delete.
    /// - Returns: An `OSStatus` code indicating success or failure.
    func secItemDelete(_ query: CFDictionary) -> OSStatus
} 