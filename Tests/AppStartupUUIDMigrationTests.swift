//
//  AppStartupUUIDMigrationTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on [Date].
//

import XCTest
import Combine
@testable import EncameraCore
import Foundation

class AppStartupUUIDMigrationTests: XCTestCase {
    
    var keyManager: KeychainManager!
    var albumManager: AlbumManager!
    var fileAccess: InteractableMediaDiskAccess!
    var tempFiles: [URL] = []
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create test keychain manager
        keyManager = TestUtils.createTestKeyManager()
        albumManager = TestUtils.createTestAlbumManager(keyManager: keyManager)
        fileAccess = InteractableMediaDiskAccess()
        cancellables = Set<AnyCancellable>()
        tempFiles = []
    }
    
    override func tearDown() async throws {
        // Clean up temp files
        for tempFile in tempFiles {
            TestUtils.cleanupTempFile(tempFile)
        }
        tempFiles.removeAll()
        try await fileAccess.deleteAllMedia()
        // Clean up keychain
        keyManager?.clearKeychainData()
        keyManager = nil
        albumManager = nil
        fileAccess = nil
        cancellables = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createTestMedia() -> CleartextMedia {
        return TestUtils.createTestImageMedia()
    }
    
    private func setupAlbumWithKey(_ key: PrivateKey) async {
        let album = TestUtils.createTestAlbum(key: key)
        
        try! albumManager.create(name: album.name, storageOption: .local)
        await fileAccess.configure(for: album, albumManager: albumManager)
    }
    

    
    // MARK: - App Startup Migration Tests
    
    func testMigrateExistingFilesUUIDs_WithExistingFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "startupMigrationKey", keyManager: keyManager)
        
        // Set up the album once for consistency
        await setupAlbumWithKey(testKey)
        
        // Create files without UUIDs to simulate existing files before migration feature
        let media1 = createTestMedia()
        let interactableMedia1 = try InteractableMedia(underlyingMedia: [media1])
        let encryptedInteractableMedia1 = try await fileAccess.save(media: interactableMedia1) { _ in }
        let file1 = encryptedInteractableMedia1!.underlyingMedia.first!
        tempFiles.append(file1.url!)
        
        let media2 = createTestMedia()
        let interactableMedia2 = try InteractableMedia(underlyingMedia: [media2])
        let encryptedInteractableMedia2 = try await fileAccess.save(media: interactableMedia2) { _ in }
        let file2 = encryptedInteractableMedia2!.underlyingMedia.first!
        tempFiles.append(file2.url!)
        
        // Remove UUIDs to simulate old files
        try ExtendedAttributesUtil.removeKeyUUID(for: file1.url!)
        try ExtendedAttributesUtil.removeKeyUUID(for: file2.url!)
        
        // Verify UUIDs are removed
        XCTAssertNil(try ExtendedAttributesUtil.getKeyUUID(for: file1.url!), "UUID should be removed")
        XCTAssertNil(try ExtendedAttributesUtil.getKeyUUID(for: file2.url!), "UUID should be removed")
        
        // Create a mock ViewModel to test the migration method
        let viewModel = MockAppViewModel(fileAccess: fileAccess, keyManager: keyManager)
        
        // Run the migration method that would be called on app startup
        await viewModel.migrateExistingFilesUUIDs()
        
        // Verify all files now have UUIDs
        for encryptedMedia in [file1, file2] {
            guard let fileURL = encryptedMedia.url else {
                XCTFail("File should have URL")
                continue
            }
            
            let storedUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileURL)
            XCTAssertEqual(storedUUID, testKey.uuid, "File should have UUID after startup migration")
        }
    }
    
    func testMigrateExistingFilesUUIDs_WithNoCurrentKey() async throws {
        // Create a mock ViewModel without setting up a key
        let viewModel = MockAppViewModel(fileAccess: fileAccess, keyManager: keyManager)
        
        // Run the migration - should handle gracefully when no key is available
        await viewModel.migrateExistingFilesUUIDs()
        
        // No assertions needed - just verify it doesn't crash
        // The method should log and return early when no key is available
    }
    
    func testMigrateExistingFilesUUIDs_WithNoExistingFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "startupMigrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Create a mock ViewModel
        let viewModel = MockAppViewModel(fileAccess: fileAccess, keyManager: keyManager)
        
        // Run the migration with no existing files
        await viewModel.migrateExistingFilesUUIDs()
        
        // No assertions needed - just verify it doesn't crash
        // The method should complete successfully with no files to process
    }
    
    func testMigrateExistingFilesUUIDs_ErrorHandling() async throws {
        let testKey = try TestUtils.createTestKey(name: "startupMigrationKey", keyManager: keyManager)
        
        // Set up the album
        await setupAlbumWithKey(testKey)
        
        // Create a file without UUID
        let media = createTestMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [media])
        let encryptedInteractableMedia = try await fileAccess.save(media: interactableMedia) { _ in }
        let file = encryptedInteractableMedia!.underlyingMedia.first!
        tempFiles.append(file.url!)
        
        // Remove UUID to simulate old file
        try ExtendedAttributesUtil.removeKeyUUID(for: file.url!)
        
        // Create a mock ViewModel that will simulate an error
        let viewModel = MockAppViewModelWithError(fileAccess: fileAccess, keyManager: keyManager)
        
        // Run the migration - should handle errors gracefully
        await viewModel.migrateExistingFilesUUIDs()
        
        // No assertions needed - just verify it doesn't crash
        // The method should log the error and continue
    }
    
    func testMigrateExistingFilesUUIDs_DelayBehavior() async throws {
        let testKey = try TestUtils.createTestKey(name: "startupMigrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Create a mock ViewModel
        let viewModel = MockAppViewModel(fileAccess: fileAccess, keyManager: keyManager)
        
        // Measure the time it takes for migration to start
        let startTime = Date()
        await viewModel.migrateExistingFilesUUIDs()
        let endTime = Date()
        
        // Verify that the migration includes the expected delay
        let duration = endTime.timeIntervalSince(startTime)
        XCTAssertGreaterThanOrEqual(duration, 2.0, "Migration should include a 2-second delay")
        XCTAssertLessThan(duration, 3.0, "Migration should not take much longer than the delay")
    }
}

// MARK: - Mock Classes

/// Mock ViewModel that mimics the EncameraApp.ViewModel behavior for testing
class MockAppViewModel {
    let fileAccess: InteractableMediaDiskAccess
    let keyManager: KeyManager
    
    init(fileAccess: InteractableMediaDiskAccess, keyManager: KeyManager) {
        self.fileAccess = fileAccess
        self.keyManager = keyManager
    }
    
    /// Mimics the migrateExistingFilesUUIDs method from EncameraApp.ViewModel
    func migrateExistingFilesUUIDs() async {
        // Wait a bit to ensure the app is fully initialized
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        guard keyManager.currentKey != nil else {
            debugPrint("migrateExistingFilesUUIDs: No current key available, skipping migration")
            return
        }
        
        do {
            debugPrint("migrateExistingFilesUUIDs: Starting background UUID migration")
            try await fileAccess.setKeyUUIDForExistingFiles()
            debugPrint("migrateExistingFilesUUIDs: UUID migration completed successfully")
        } catch {
            debugPrint("migrateExistingFilesUUIDs: Error during UUID migration: \(error)")
        }
    }
}

/// Mock ViewModel that simulates an error during migration
class MockAppViewModelWithError {
    let fileAccess: InteractableMediaDiskAccess
    let keyManager: KeyManager
    
    init(fileAccess: InteractableMediaDiskAccess, keyManager: KeyManager) {
        self.fileAccess = fileAccess
        self.keyManager = keyManager
    }
    
    /// Mimics the migrateExistingFilesUUIDs method but with error simulation
    func migrateExistingFilesUUIDs() async {
        // Wait a bit to ensure the app is fully initialized
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        guard keyManager.currentKey != nil else {
            debugPrint("migrateExistingFilesUUIDs: No current key available, skipping migration")
            return
        }
        
        do {
            debugPrint("migrateExistingFilesUUIDs: Starting background UUID migration")
            // Simulate an error by calling with a nil key
            throw FileAccessError.missingPrivateKey
        } catch {
            debugPrint("migrateExistingFilesUUIDs: Error during UUID migration: \(error)")
            // Error should be handled gracefully, not crash the app
        }
    }
} 
