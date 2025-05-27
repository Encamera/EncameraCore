//
//  UUIDMigrationTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on [Date].
//

import XCTest
import Combine
@testable import EncameraCore
import Foundation

class UUIDMigrationTests: XCTestCase {
    
    var keyManager: KeychainManager!
    var albumManager: AlbumManager!
    var diskFileAccess: DiskFileAccess!
    var interactableFileAccess: InteractableMediaDiskAccess!
    var tempFiles: [URL] = []
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create test keychain manager
        keyManager = TestUtils.createTestKeyManager()
        albumManager = TestUtils.createTestAlbumManager(keyManager: keyManager)
        diskFileAccess = DiskFileAccess()
        interactableFileAccess = InteractableMediaDiskAccess()
        cancellables = Set<AnyCancellable>()
        tempFiles = []
    }
    
    override func tearDown() async throws {
        // Clean up temp files
        for tempFile in tempFiles {
            TestUtils.cleanupTempFile(tempFile)
        }
        tempFiles.removeAll()
        try await diskFileAccess.deleteAllMedia()
        // Clean up keychain
        keyManager?.clearKeychainData()
        keyManager = nil
        albumManager = nil
        diskFileAccess = nil
        interactableFileAccess = nil
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
        await diskFileAccess.configure(for: album, albumManager: albumManager)
        await interactableFileAccess.configure(for: album, albumManager: albumManager)
    }
    
    private func createEncryptedFileWithoutUUID(_ key: PrivateKey) async throws -> EncryptedMedia {
        // Don't call setupAlbumWithKey here - assume it's already been called once
        
        let media = createTestMedia()
        let encryptedMedia = try await diskFileAccess.save(media: media) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Should create encrypted media")
        guard let encryptedURL = encryptedMedia?.url else {
            XCTFail("Encrypted media should have a URL")
            throw FileAccessError.couldNotLoadMedia
        }
        
        tempFiles.append(encryptedURL)
        
        // Remove the UUID to simulate an old file
        try ExtendedAttributesUtil.removeKeyUUID(for: encryptedURL)
        
        // Verify UUID is removed
        let removedUUID = try ExtendedAttributesUtil.getKeyUUID(for: encryptedURL)
        XCTAssertNil(removedUUID, "UUID should be removed to simulate old file")
        
        return encryptedMedia!
    }
    
    // MARK: - DiskFileAccess Tests
    
    func testSetKeyUUIDForExistingFiles_WithNoExistingFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "migrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Test with no existing files - should complete without error
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // No assertions needed - just verify it doesn't throw
    }
    
    func testSetKeyUUIDForExistingFiles_WithFilesWithoutUUID() async throws {
        let testKey = try TestUtils.createTestKey(name: "migrationKey", keyManager: keyManager)
        
        // Set up the album once for all files
        await setupAlbumWithKey(testKey)
        
        // Create multiple files without UUIDs
        let file1 = try await createEncryptedFileWithoutUUID(testKey)
        let file2 = try await createEncryptedFileWithoutUUID(testKey)
        let file3 = try await createEncryptedFileWithoutUUID(testKey)

        // Run the migration
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify all files now have the correct UUID
        for encryptedMedia in [file1, file2, file3] {
            guard let fileURL = encryptedMedia.url else {
                XCTFail("File should have URL")
                continue
            }
            
            let storedUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileURL)
            XCTAssertEqual(storedUUID, testKey.uuid, "File should have the migration key's UUID")
        }
    }
    
    func testSetKeyUUIDForExistingFiles_WithMixedFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "migrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Create one file without UUID
        let fileWithoutUUID = try await createEncryptedFileWithoutUUID(testKey)
        
        // Create one file with UUID (normal save)
        let media = createTestMedia()
        let fileWithUUID = try await diskFileAccess.save(media: media) { _ in }
        
        XCTAssertNotNil(fileWithUUID, "Should create encrypted media")
        guard let fileWithUUIDURL = fileWithUUID?.url else {
            XCTFail("Encrypted media should have a URL")
            return
        }
        tempFiles.append(fileWithUUIDURL)
        
        // Verify the second file already has UUID
        let existingUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileWithUUIDURL)
        XCTAssertEqual(existingUUID, testKey.uuid, "New file should already have UUID")
        
        // Run the migration
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify the file without UUID now has it
        guard let fileWithoutUUIDURL = fileWithoutUUID.url else {
            XCTFail("File should have URL")
            return
        }
        
        let migratedUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileWithoutUUIDURL)
        XCTAssertEqual(migratedUUID, testKey.uuid, "File without UUID should now have the migration key's UUID")
        
        // Verify the file that already had UUID is unchanged
        let unchangedUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileWithUUIDURL)
        XCTAssertEqual(unchangedUUID, testKey.uuid, "File with existing UUID should be unchanged")
    }
    
    func testSetKeyUUIDForExistingFiles_WithoutCurrentKey() async throws {
        // Don't create any key or set up any album - just configure diskFileAccess with a keyManager that has no current key
        // This simulates the scenario where setKeyUUIDForExistingFiles is called without a current key
        
        // Create a dummy album for configuration (but don't create it through albumManager)
        let dummyKey = try TestUtils.createTestKey(name: "dummyKey", keyManager: keyManager, setAsCurrent: false)
        let album = TestUtils.createTestAlbum(key: dummyKey)
        
        // Configure diskFileAccess directly without going through albumManager.create()
        await diskFileAccess.configure(for: album, albumManager: albumManager)
        
        // Verify that keyManager.currentKey is nil
        XCTAssertNil(keyManager.currentKey, "KeyManager should have no current key")
        
        do {
            try await diskFileAccess.setKeyUUIDForExistingFiles()
            XCTFail("Should throw error when no current key is available")
        } catch FileAccessError.missingPrivateKey {
            // Expected error
        } catch {
            XCTFail("Should throw missingPrivateKey error, got: \(error)")
        }
    }
    
    func testSetKeyUUIDForExistingFiles_WithPreviewFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "migrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Create a file which will also create a preview
        let media = createTestMedia()
        let encryptedMedia = try await diskFileAccess.save(media: media) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Should create encrypted media")
        guard let encryptedURL = encryptedMedia?.url else {
            XCTFail("Encrypted media should have a URL")
            return
        }
        tempFiles.append(encryptedURL)
        
        // Remove UUIDs from both main file and preview to simulate old files
        try ExtendedAttributesUtil.removeKeyUUID(for: encryptedURL)
        
        // Find and remove UUID from preview file
        if let directoryModel = await diskFileAccess.directoryModel {
            let previewFiles = directoryModel.enumeratePreviewFiles()
            for previewURL in previewFiles {
                try? ExtendedAttributesUtil.removeKeyUUID(for: previewURL)
            }
        }
        
        // Run the migration
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify main file has UUID
        let mainFileUUID = try ExtendedAttributesUtil.getKeyUUID(for: encryptedURL)
        XCTAssertEqual(mainFileUUID, testKey.uuid, "Main file should have UUID after migration")
        
        // Verify preview files have UUID
        if let directoryModel = await diskFileAccess.directoryModel {
            let previewFiles = directoryModel.enumeratePreviewFiles()
            for previewURL in previewFiles {
                let previewUUID = try ExtendedAttributesUtil.getKeyUUID(for: previewURL)
                XCTAssertEqual(previewUUID, testKey.uuid, "Preview file should have UUID after migration")
            }
        }
    }
    
    // MARK: - InteractableMediaDiskAccess Tests
    
    func testInteractableMediaDiskAccess_SetKeyUUIDForExistingFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "interactableMigrationKey", keyManager: keyManager)
        
        // Set up the album once
        await setupAlbumWithKey(testKey)
        
        // Create file without UUID using the underlying disk access
        let fileWithoutUUID = try await createEncryptedFileWithoutUUID(testKey)
        
        // Run migration through InteractableMediaDiskAccess
        try await interactableFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify the file now has UUID
        guard let fileURL = fileWithoutUUID.url else {
            XCTFail("File should have URL")
            return
        }
        
        let migratedUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileURL)
        XCTAssertEqual(migratedUUID, testKey.uuid, "File should have UUID after migration through InteractableMediaDiskAccess")
    }
    
    // MARK: - Edge Cases
    
    func testSetKeyUUIDForExistingFiles_WithCorruptedFiles() async throws {
        let testKey = try TestUtils.createTestKey(name: "migrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Create a file without UUID
        let fileWithoutUUID = try await createEncryptedFileWithoutUUID(testKey)
        
        // Create a temporary file that looks like an encrypted file but isn't valid
        let tempDir = FileManager.default.temporaryDirectory
        let corruptedFileURL = tempDir.appendingPathComponent("corrupted.\(MediaType.photo.encryptedFileExtension)")
        let corruptedData = Data([1, 2, 3, 4, 5]) // Invalid encrypted data
        try corruptedData.write(to: corruptedFileURL)
        tempFiles.append(corruptedFileURL)
        
        // Run migration - should handle corrupted files gracefully
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify the valid file still gets migrated
        guard let validFileURL = fileWithoutUUID.url else {
            XCTFail("File should have URL")
            return
        }
        
        let migratedUUID = try ExtendedAttributesUtil.getKeyUUID(for: validFileURL)
        XCTAssertEqual(migratedUUID, testKey.uuid, "Valid file should have UUID after migration")
    }
    
    func testSetKeyUUIDForExistingFiles_MultipleCallsIdempotent() async throws {
        let testKey = try TestUtils.createTestKey(name: "migrationKey", keyManager: keyManager)
        await setupAlbumWithKey(testKey)
        
        // Create file without UUID
        let fileWithoutUUID = try await createEncryptedFileWithoutUUID(testKey)
        
        // Run migration first time
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify UUID is set
        guard let fileURL = fileWithoutUUID.url else {
            XCTFail("File should have URL")
            return
        }
        
        let firstMigrationUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileURL)
        XCTAssertEqual(firstMigrationUUID, testKey.uuid, "File should have UUID after first migration")
        
        // Run migration second time
        try await diskFileAccess.setKeyUUIDForExistingFiles()
        
        // Verify UUID is unchanged
        let secondMigrationUUID = try ExtendedAttributesUtil.getKeyUUID(for: fileURL)
        XCTAssertEqual(secondMigrationUUID, testKey.uuid, "File UUID should be unchanged after second migration")
        XCTAssertEqual(firstMigrationUUID, secondMigrationUUID, "UUID should be identical after multiple migrations")
    }
} 
