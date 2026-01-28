//
//  KeyValueStoreProtocol.swift
//  EncameraCore
//
//  Created for iCloud synced data store feature.
//

import Foundation

// MARK: - Protocol Definition

/// Protocol wrapper for NSUbiquitousKeyValueStore to enable mocking in unit tests
/// Allows injection of mock storage for testing without requiring iCloud connection
public protocol KeyValueStoreProtocol {
    /// Sets a value for the specified key
    func set(_ value: Any?, forKey key: String)
    
    /// Returns the dictionary for the specified key
    func dictionary(forKey key: String) -> [String: Any]?
    
    /// Removes the value for the specified key
    func removeObject(forKey key: String)
    
    /// Requests synchronization with iCloud
    /// - Returns: True if synchronization was initiated successfully
    @discardableResult
    func synchronize() -> Bool
    
    /// The notification posted when values change externally
    var externalChangeNotification: Notification.Name { get }
}

// MARK: - Production Implementation

extension NSUbiquitousKeyValueStore: KeyValueStoreProtocol {
    public var externalChangeNotification: Notification.Name {
        NSUbiquitousKeyValueStore.didChangeExternallyNotification
    }
}

// MARK: - Mock Implementation for Testing

/// Mock implementation of KeyValueStoreProtocol for unit testing
/// Stores data in memory and provides helpers to simulate iCloud sync behavior
public class MockKeyValueStore: KeyValueStoreProtocol {
    
    /// In-memory storage backing
    public var storage: [String: Any] = [:]
    
    /// Tracks whether synchronize() was called
    public var synchronizeCalled = false
    
    /// Notification name for mock external changes
    public var externalChangeNotification = Notification.Name("MockDidChangeExternally")
    
    public init() {}
    
    public func set(_ value: Any?, forKey key: String) {
        if let value = value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
    
    public func dictionary(forKey key: String) -> [String: Any]? {
        storage[key] as? [String: Any]
    }
    
    public func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
    
    @discardableResult
    public func synchronize() -> Bool {
        synchronizeCalled = true
        return true
    }
    
    // MARK: - Test Helpers
    
    /// Resets the mock store to initial state
    public func reset() {
        storage.removeAll()
        synchronizeCalled = false
    }
    
    /// Simulates an external change notification (e.g., from another device)
    /// - Parameter keys: The keys that changed
    public func simulateExternalChange(keys: [String]) {
        NotificationCenter.default.post(
            name: externalChangeNotification,
            object: self,
            userInfo: [
                NSUbiquitousKeyValueStoreChangedKeysKey: keys,
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange
            ]
        )
    }
    
    /// Simulates an initial sync change notification
    /// - Parameter keys: The keys that changed
    public func simulateInitialSyncChange(keys: [String]) {
        NotificationCenter.default.post(
            name: externalChangeNotification,
            object: self,
            userInfo: [
                NSUbiquitousKeyValueStoreChangedKeysKey: keys,
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange
            ]
        )
    }
    
    /// Simulates a quota violation notification
    public func simulateQuotaViolation() {
        NotificationCenter.default.post(
            name: externalChangeNotification,
            object: self,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreQuotaViolationChange
            ]
        )
    }
}
