//
//  SyncedStoreEncryptionHandler.swift
//  EncameraCore
//
//  Created for iCloud synced data store feature.
//

import Foundation
import Sodium

// MARK: - Encryption Errors

public enum SyncedStoreEncryptionError: Error, CustomStringConvertible {
    case noEncryptionKeyAvailable
    case encryptionFailed
    case decryptionFailed
    case invalidBase64
    case invalidEncryptedData
    
    public var description: String {
        switch self {
        case .noEncryptionKeyAvailable:
            return "No encryption key available"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .invalidBase64:
            return "Invalid base64 encoded data"
        case .invalidEncryptedData:
            return "Invalid encrypted data format"
        }
    }
}

// MARK: - Encryption Handler

/// Handles encryption and decryption of field values for synced data storage
/// Uses XChaCha20-Poly1305 stream encryption via Sodium library
public class SyncedStoreEncryptionHandler {
    
    private let keyManager: KeyManager
    private let sodium = Sodium()
    
    // MARK: - Initialization
    
    public init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }
    
    // MARK: - Key Availability
    
    /// Whether an encryption key is currently available
    public var isKeyAvailable: Bool {
        keyManager.currentKey != nil
    }
    
    /// The current encryption key bytes, if available
    private var keyBytes: [UInt8]? {
        keyManager.currentKey?.keyBytes
    }
    
    // MARK: - String Encryption/Decryption
    
    /// Encrypts a string value using XChaCha20-Poly1305
    /// - Parameter value: The plaintext string to encrypt
    /// - Returns: Base64-encoded encrypted data (includes stream header)
    /// - Throws: SyncedStoreEncryptionError if encryption fails
    public func encrypt(_ value: String) throws -> String {
        guard let keyBytes = keyBytes else {
            throw SyncedStoreEncryptionError.noEncryptionKeyAvailable
        }
        
        let messageBytes = Array(value.utf8)
        
        // Create encryption stream
        guard let streamPush = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            throw SyncedStoreEncryptionError.encryptionFailed
        }
        
        // Encrypt as single sealed message with FINAL tag
        let header = streamPush.header()
        guard let cipherText = streamPush.push(message: messageBytes, tag: .FINAL) else {
            throw SyncedStoreEncryptionError.encryptionFailed
        }
        
        // Combine header and ciphertext
        var encryptedData = Data()
        encryptedData.append(contentsOf: header)
        encryptedData.append(contentsOf: cipherText)
        
        // Return as base64
        return encryptedData.base64EncodedString()
    }
    
    /// Decrypts a base64-encoded encrypted string
    /// - Parameter encryptedValue: Base64-encoded encrypted data
    /// - Returns: The original plaintext string
    /// - Throws: SyncedStoreEncryptionError if decryption fails
    public func decrypt(_ encryptedValue: String) throws -> String {
        guard let keyBytes = keyBytes else {
            throw SyncedStoreEncryptionError.noEncryptionKeyAvailable
        }
        
        // Decode base64
        guard let encryptedData = Data(base64Encoded: encryptedValue) else {
            throw SyncedStoreEncryptionError.invalidBase64
        }
        
        let encryptedBytes = Array(encryptedData)
        
        // Extract header and ciphertext
        let headerSize = SecretStream.XChaCha20Poly1305.HeaderBytes
        guard encryptedBytes.count > headerSize else {
            throw SyncedStoreEncryptionError.invalidEncryptedData
        }
        
        let header = Array(encryptedBytes.prefix(headerSize))
        let cipherText = Array(encryptedBytes.dropFirst(headerSize))
        
        // Initialize decryption stream
        guard let streamPull = sodium.secretStream.xchacha20poly1305.initPull(
            secretKey: keyBytes,
            header: header
        ) else {
            throw SyncedStoreEncryptionError.decryptionFailed
        }
        
        // Decrypt
        guard let (decryptedBytes, _) = streamPull.pull(cipherText: cipherText) else {
            throw SyncedStoreEncryptionError.decryptionFailed
        }
        
        // Convert back to string
        guard let decryptedString = String(bytes: decryptedBytes, encoding: .utf8) else {
            throw SyncedStoreEncryptionError.decryptionFailed
        }
        
        return decryptedString
    }
    
    // MARK: - Record Encryption/Decryption
    
    /// Encrypts fields in a record dictionary according to schema encryption flags
    /// - Parameters:
    ///   - record: The record dictionary with plaintext values
    ///   - schema: The table schema defining which fields to encrypt
    /// - Returns: A new dictionary with encrypted fields
    /// - Throws: SyncedStoreEncryptionError if encryption fails
    public func encryptRecord(_ record: [String: Any], schema: SyncedTableSchema) throws -> [String: Any] {
        var encryptedRecord = record
        
        for field in schema.encryptedFields {
            if let stringValue = record[field.name] as? String {
                encryptedRecord[field.name] = try encrypt(stringValue)
            }
            // Non-string encrypted fields could be converted to string first if needed
            // For now, we only support string encryption
        }
        
        // Convert Date fields to TimeInterval for storage
        for field in schema.fields where field.type == .date {
            if let dateValue = record[field.name] as? Date {
                encryptedRecord[field.name] = dateValue.timeIntervalSince1970
            }
        }
        
        return encryptedRecord
    }
    
    /// Decrypts fields in a record dictionary according to schema encryption flags
    /// - Parameters:
    ///   - record: The record dictionary with encrypted values
    ///   - schema: The table schema defining which fields to decrypt
    /// - Returns: A new dictionary with decrypted fields
    /// - Throws: SyncedStoreEncryptionError if decryption fails
    public func decryptRecord(_ record: [String: Any], schema: SyncedTableSchema) throws -> [String: Any] {
        var decryptedRecord = record
        
        for field in schema.encryptedFields {
            if let encryptedValue = record[field.name] as? String {
                decryptedRecord[field.name] = try decrypt(encryptedValue)
            }
        }
        
        // Convert TimeInterval back to Date for date fields
        for field in schema.fields where field.type == .date {
            if let timeInterval = record[field.name] as? TimeInterval {
                decryptedRecord[field.name] = Date(timeIntervalSince1970: timeInterval)
            } else if let timeInterval = record[field.name] as? Double {
                decryptedRecord[field.name] = Date(timeIntervalSince1970: timeInterval)
            }
        }
        
        return decryptedRecord
    }
    
    /// Safely attempts to decrypt a record, returning nil on failure instead of throwing
    /// - Parameters:
    ///   - record: The record dictionary with encrypted values
    ///   - schema: The table schema defining which fields to decrypt
    /// - Returns: A decrypted dictionary, or nil if decryption fails
    public func tryDecryptRecord(_ record: [String: Any], schema: SyncedTableSchema) -> [String: Any]? {
        do {
            return try decryptRecord(record, schema: schema)
        } catch {
            return nil
        }
    }
    
    // MARK: - Primary Key Hashing
    
    /// Hashes a primary key value for use as a storage dictionary key
    /// Uses BLAKE2b keyed hash for deterministic but privacy-preserving storage keys
    /// - Parameter value: The plaintext primary key value
    /// - Returns: A base64-encoded hash suitable for use as a dictionary key
    /// - Throws: SyncedStoreEncryptionError if hashing fails
    public func hashPrimaryKey(_ value: String) throws -> String {
        guard let keyBytes = keyBytes else {
            throw SyncedStoreEncryptionError.noEncryptionKeyAvailable
        }
        
        let messageBytes = Array(value.utf8)
        
        // Use BLAKE2b keyed hash (16 bytes output for compact keys)
        guard let hash = sodium.genericHash.hash(
            message: messageBytes,
            key: keyBytes,
            outputLength: 16
        ) else {
            throw SyncedStoreEncryptionError.encryptionFailed
        }
        
        // Convert to base64 for safe dictionary key usage
        return Data(hash).base64EncodedString()
    }
    
    /// Safely attempts to hash a primary key, returning nil on failure
    /// - Parameter value: The plaintext primary key value
    /// - Returns: A base64-encoded hash, or nil if hashing fails
    public func tryHashPrimaryKey(_ value: String) -> String? {
        do {
            return try hashPrimaryKey(value)
        } catch {
            return nil
        }
    }
}
