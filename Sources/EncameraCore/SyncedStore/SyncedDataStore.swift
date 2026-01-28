//
//  SyncedDataStore.swift
//  EncameraCore
//
//  Created for iCloud synced data store feature.
//

import Foundation
import Combine

// MARK: - Store Errors

public enum SyncedStoreError: Error, CustomStringConvertible {
    case noEncryptionKeyAvailable
    case encryptionFailed
    case decryptionFailed
    case recordNotFound
    case invalidData
    case invalidPredicate(String)
    case saveFailed
    
    public var description: String {
        switch self {
        case .noEncryptionKeyAvailable:
            return "No encryption key available for encrypted fields"
        case .encryptionFailed:
            return "Failed to encrypt record"
        case .decryptionFailed:
            return "Failed to decrypt record"
        case .recordNotFound:
            return "Record not found"
        case .invalidData:
            return "Invalid data format"
        case .invalidPredicate(let message):
            return "Invalid predicate: \(message)"
        case .saveFailed:
            return "Failed to save record"
        }
    }
}

// MARK: - Synced Data Store

/// Core storage abstraction for iCloud-synced data with automatic encryption
/// Uses UserDefaults as the primary offline-first storage, with NSUbiquitousKeyValueStore for cloud sync
public class SyncedDataStore: ObservableObject {
    
    // MARK: - Dependencies
    
    private let encryptionHandler: SyncedStoreEncryptionHandler
    private let defaults: UserDefaults
    private let cloudStore: KeyValueStoreProtocol
    
    // MARK: - Observers
    
    private var iCloudObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    
    /// Publisher that emits when external changes are received from iCloud
    public let externalChangePublisher = PassthroughSubject<[String], Never>()
    
    // MARK: - Initialization
    
    /// Creates a new SyncedDataStore
    /// - Parameters:
    ///   - keyManager: The key manager for encryption operations
    ///   - defaults: Optional UserDefaults instance (defaults to app group defaults)
    ///   - cloudStore: Optional cloud store (defaults to NSUbiquitousKeyValueStore.default)
    public init(
        keyManager: KeyManager,
        defaults: UserDefaults? = nil,
        cloudStore: KeyValueStoreProtocol? = nil
    ) {
        self.encryptionHandler = SyncedStoreEncryptionHandler(keyManager: keyManager)
        self.defaults = defaults ?? UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
        self.cloudStore = cloudStore ?? NSUbiquitousKeyValueStore.default
        
        setupiCloudObserver()
    }
    
    deinit {
        if let observer = iCloudObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - iCloud Sync
    
    private func setupiCloudObserver() {
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: cloudStore.externalChangeNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            self?.handleiCloudChange(notification)
        }
        
        // Trigger initial sync
        cloudStore.synchronize()
    }
    
    private func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        // Check the change reason
        if let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
            switch changeReason {
            case NSUbiquitousKeyValueStoreServerChange,
                 NSUbiquitousKeyValueStoreInitialSyncChange:
                // Valid sync changes - proceed
                break
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                print("[SyncedDataStore] WARNING: iCloud quota violation")
                return
            case NSUbiquitousKeyValueStoreAccountChange:
                print("[SyncedDataStore] iCloud account changed - resyncing")
            default:
                break
            }
        }
        
        // Get the changed keys
        if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            // Sync changed values from cloud to local
            for keyString in changedKeys {
                if let cloudValue = cloudStore.dictionary(forKey: keyString) {
                    defaults.set(cloudValue, forKey: keyString)
                    print("[SyncedDataStore] Synced from iCloud: \(keyString)")
                }
            }
            
            // Notify observers
            externalChangePublisher.send(changedKeys)
        }
    }
    
    // MARK: - CRUD Operations
    
    /// Saves a record to storage with automatic encryption of marked fields
    /// - Parameters:
    ///   - record: The record dictionary to save
    ///   - schema: The table schema defining storage and encryption
    /// - Throws: SyncedStoreError if save fails
    public func save(_ record: [String: Any], schema: SyncedTableSchema) throws {
        guard schema.validateRecord(record) else {
            throw SyncedStoreError.invalidData
        }
        
        guard let primaryKeyValue = schema.primaryKeyValue(from: record) else {
            throw SyncedStoreError.invalidData
        }
        
        // Hash the primary key if it's an encrypted field (for privacy)
        let storageKey: String
        if schema.isPrimaryKeyEncrypted {
            do {
                storageKey = try encryptionHandler.hashPrimaryKey(primaryKeyValue)
            } catch {
                throw SyncedStoreError.encryptionFailed
            }
        } else {
            storageKey = primaryKeyValue
        }
        
        // Encrypt fields as needed
        let recordToStore: [String: Any]
        if schema.encryptedFields.isEmpty {
            recordToStore = convertDatesToTimeIntervals(record, schema: schema)
        } else {
            do {
                recordToStore = try encryptionHandler.encryptRecord(record, schema: schema)
            } catch {
                throw SyncedStoreError.encryptionFailed
            }
        }
        
        // Load existing table data
        var tableData = loadTableData(schema: schema)
        
        // Update with new record using hashed key for privacy
        tableData[storageKey] = recordToStore
        
        // Save to local storage first (offline-first)
        defaults.set(tableData, forKey: schema.storageKey)
        
        // Sync to iCloud (opportunistic)
        cloudStore.set(tableData, forKey: schema.storageKey)
        cloudStore.synchronize()
        
        print("[SyncedDataStore] Saved record to \(schema.tableName)")
    }
    
    /// Fetches a single record by primary key
    /// - Parameters:
    ///   - primaryKey: The primary key value (plaintext - will be hashed if needed)
    ///   - schema: The table schema
    /// - Returns: The decrypted record, or nil if not found
    /// - Throws: SyncedStoreError if decryption fails
    public func fetch(primaryKey: String, schema: SyncedTableSchema) throws -> [String: Any]? {
        let tableData = loadTableData(schema: schema)
        
        // Hash the primary key if it's an encrypted field
        let storageKey: String
        if schema.isPrimaryKeyEncrypted {
            do {
                storageKey = try encryptionHandler.hashPrimaryKey(primaryKey)
            } catch {
                throw SyncedStoreError.decryptionFailed
            }
        } else {
            storageKey = primaryKey
        }
        
        guard let rawRecord = tableData[storageKey] as? [String: Any] else {
            return nil
        }
        
        // Decrypt if needed
        if schema.encryptedFields.isEmpty {
            return convertTimeIntervalsToDates(rawRecord, schema: schema)
        } else {
            do {
                return try encryptionHandler.decryptRecord(rawRecord, schema: schema)
            } catch {
                throw SyncedStoreError.decryptionFailed
            }
        }
    }
    
    /// Deletes a record by primary key
    /// - Parameters:
    ///   - primaryKey: The primary key value (plaintext - will be hashed if needed)
    ///   - schema: The table schema
    public func delete(primaryKey: String, schema: SyncedTableSchema) {
        var tableData = loadTableData(schema: schema)
        
        // Hash the primary key if it's an encrypted field
        let storageKey: String
        if schema.isPrimaryKeyEncrypted {
            guard let hashedKey = encryptionHandler.tryHashPrimaryKey(primaryKey) else {
                print("[SyncedDataStore] Failed to hash primary key for deletion")
                return
            }
            storageKey = hashedKey
        } else {
            storageKey = primaryKey
        }
        
        tableData.removeValue(forKey: storageKey)
        
        // Save to local storage
        defaults.set(tableData, forKey: schema.storageKey)
        
        // Sync to iCloud
        cloudStore.set(tableData, forKey: schema.storageKey)
        cloudStore.synchronize()
        
        print("[SyncedDataStore] Deleted record from \(schema.tableName)")
    }
    
    // MARK: - Query Operations
    
    /// Fetches all records, optionally filtered and sorted
    /// - Parameters:
    ///   - schema: The table schema
    ///   - predicate: Optional NSPredicate to filter records (operates on decrypted data)
    ///   - sortDescriptors: Optional sort descriptors
    /// - Returns: Array of decrypted records matching the criteria
    /// - Throws: SyncedStoreError if decryption fails
    public func fetchAll(
        schema: SyncedTableSchema,
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor]? = nil
    ) throws -> [[String: Any]] {
        let tableData = loadTableData(schema: schema)
        
        // Decrypt all records
        var records: [[String: Any]] = []
        for (_, value) in tableData {
            guard let rawRecord = value as? [String: Any] else { continue }
            
            let decryptedRecord: [String: Any]
            if schema.encryptedFields.isEmpty {
                decryptedRecord = convertTimeIntervalsToDates(rawRecord, schema: schema)
            } else {
                // Try to decrypt, skip records that fail
                guard let record = encryptionHandler.tryDecryptRecord(rawRecord, schema: schema) else {
                    continue
                }
                decryptedRecord = record
            }
            records.append(decryptedRecord)
        }
        
        // Apply predicate filter if provided
        if let predicate = predicate {
            records = (records as NSArray).filtered(using: predicate) as? [[String: Any]] ?? []
        }
        
        // Apply sorting if provided
        if let sortDescriptors = sortDescriptors {
            records = (records as NSArray).sortedArray(using: sortDescriptors) as? [[String: Any]] ?? records
        }
        
        return records
    }
    
    /// Counts records matching an optional predicate
    /// - Parameters:
    ///   - schema: The table schema
    ///   - predicate: Optional NSPredicate to filter records
    /// - Returns: The count of matching records
    public func count(schema: SyncedTableSchema, predicate: NSPredicate? = nil) throws -> Int {
        return try fetchAll(schema: schema, predicate: predicate).count
    }
    
    // MARK: - Private Helpers
    
    /// Loads the raw table data from storage (prefers local, falls back to cloud)
    internal func loadTableData(schema: SyncedTableSchema) -> [String: Any] {
        // Try local storage first
        if let localData = defaults.dictionary(forKey: schema.storageKey) {
            return localData
        }
        
        // Fall back to cloud storage
        if let cloudData = cloudStore.dictionary(forKey: schema.storageKey) {
            // Cache locally
            defaults.set(cloudData, forKey: schema.storageKey)
            return cloudData
        }
        
        return [:]
    }
    
    /// Converts Date values to TimeInterval for storage
    private func convertDatesToTimeIntervals(_ record: [String: Any], schema: SyncedTableSchema) -> [String: Any] {
        var converted = record
        for field in schema.fields where field.type == .date {
            if let dateValue = record[field.name] as? Date {
                converted[field.name] = dateValue.timeIntervalSince1970
            }
        }
        return converted
    }
    
    /// Converts TimeInterval values back to Date
    private func convertTimeIntervalsToDates(_ record: [String: Any], schema: SyncedTableSchema) -> [String: Any] {
        var converted = record
        for field in schema.fields where field.type == .date {
            if let timeInterval = record[field.name] as? TimeInterval {
                converted[field.name] = Date(timeIntervalSince1970: timeInterval)
            } else if let timeInterval = record[field.name] as? Double {
                converted[field.name] = Date(timeIntervalSince1970: timeInterval)
            }
        }
        return converted
    }
    
    // MARK: - Utility
    
    /// Clears all data for a given schema
    /// - Parameter schema: The table schema to clear
    public func clearAll(schema: SyncedTableSchema) {
        defaults.removeObject(forKey: schema.storageKey)
        cloudStore.removeObject(forKey: schema.storageKey)
        cloudStore.synchronize()
        print("[SyncedDataStore] Cleared all data for \(schema.tableName)")
    }
    
    /// Forces a sync with iCloud
    @discardableResult
    public func forceSync() -> Bool {
        return cloudStore.synchronize()
    }
}
