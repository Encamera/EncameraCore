//
//  TestUtils.swift
//  EncameraTests
//
//  Created by Alexander Freas on [Date].
//

import XCTest
import Combine
@testable import EncameraCore
import Foundation

// MARK: - Test Utilities

/// Shared utilities for testing keychain and file operations
public class TestUtils {
    
    /// Creates a test PrivateKey with random bytes
    public static func createTestKey(name: String = "testKey", keyManager: KeychainManager, setAsCurrent: Bool = true) throws -> PrivateKey {
        let keyBytes = TestDataGenerator.generateRandomKeyBytes()
        let key = PrivateKey(name: name, keyBytes: keyBytes, creationDate: Date())
        try keyManager.save(key: key, setNewKeyToCurrent: setAsCurrent)
        return key
    }
    
    /// Creates a temporary file for testing
    public static func createTempFile(content: String = "Test file content") -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent("test_file_\(UUID().uuidString).txt")
        let testData = content.data(using: .utf8)!
        try! testData.write(to: tempFileURL)
        return tempFileURL
    }
    
    /// Creates a temporary image file for testing
    public static func createTempImageFile() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent("test_image_\(UUID().uuidString).jpg")
        
        // Create a simple 1x1 pixel image
        let image = UIImage(systemName: "photo")!
        let imageData = image.jpegData(compressionQuality: 1.0)!
        try! imageData.write(to: tempFileURL)
        return tempFileURL
    }
    
    /// Creates test media using the dog.jpg file from EncameraCore
    public static func createTestImageMedia() -> CleartextMedia {
        // Use the actual dog.jpg file from EncameraCore for realistic testing
        let dogImagePath = "/Users/akfreas/github/EncameraApp/EncameraCore/dog.jpg"
        let dogImageURL = URL(fileURLWithPath: dogImagePath)
        
        if FileManager.default.fileExists(atPath: dogImagePath),
           let imageData = try? Data(contentsOf: dogImageURL) {
            return CleartextMedia(source: imageData, mediaType: .photo, id: UUID().uuidString)
        } else {
            // Fallback to creating a simple test image if dog.jpg is not found
            let image = UIImage(systemName: "photo.fill") ?? UIImage()
            let imageData = image.jpegData(compressionQuality: 0.8) ?? Data()
            return CleartextMedia(source: imageData, mediaType: .photo, id: UUID().uuidString)
        }
    }
    
    /// Cleans up a temporary file
    public static func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    /// Creates a KeychainManager for testing
    public static func createTestKeyManager() -> KeychainManager {
        let isAuthenticatedPublisher = Just(true).eraseToAnyPublisher()
        let keyManager = KeychainManager(isAuthenticated: isAuthenticatedPublisher)
        keyManager.clearKeychainData()
        return keyManager
    }
    
    /// Creates a test Album with the given key
    public static func createTestAlbum(name: String = "TestAlbum", key: PrivateKey, storageType: StorageType = .local) -> Album {
        return Album(name: name, storageOption: storageType, creationDate: Date(), key: key)
    }
    
    /// Creates a test AlbumManager
    public static func createTestAlbumManager(keyManager: KeychainManager) -> AlbumManager {
        return AlbumManager(keyManager: keyManager)
    }
    
    /// Waits for a short time to allow async operations to complete
    public static func waitForAsyncOperations() {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

// MARK: - Test Data Generator Extension

extension TestDataGenerator {
    /// Generates test media content
    public static func generateTestMediaData() -> Data {
        return "Test media content for encryption".data(using: .utf8)!
    }
} 
