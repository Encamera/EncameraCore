//
//  MediaOperationsTests.swift
//  EncameraTests
//
//  Tests for media move and delete operations
//

import XCTest
import Combine
import SwiftUI
@testable import EncameraCore
@testable import Encamera
import Foundation

class MediaOperationsTests: XCTestCase {
    
    var keyManager: KeychainManager!
    var albumManager: AlbumManager!
    var sourceAlbum: Album!
    var targetAlbum: Album!
    var sourceDiskAccess: InteractableMediaDiskAccess!
    var targetDiskAccess: InteractableMediaDiskAccess!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create test keychain manager
        keyManager = TestUtils.createTestKeyManager()
        albumManager = TestUtils.createTestAlbumManager(keyManager: keyManager)
        cancellables = Set<AnyCancellable>()
        
        // Create two test albums
        _ = try TestUtils.createTestKey(name: "sourceKey", keyManager: keyManager)
        _ = try TestUtils.createTestKey(name: "targetKey", keyManager: keyManager)
        
        sourceAlbum = try albumManager.create(name: "SourceAlbum", storageOption: .local)
        targetAlbum = try albumManager.create(name: "TargetAlbum", storageOption: .local)
        
        // Set up file access for both albums
        sourceDiskAccess = await InteractableMediaDiskAccess(for: sourceAlbum, albumManager: albumManager)
        targetDiskAccess = await InteractableMediaDiskAccess(for: targetAlbum, albumManager: albumManager)
    }
    
    override func tearDown() async throws {
        // Clean up albums
        if let sourceAlbum = sourceAlbum {
            albumManager.delete(album: sourceAlbum)
        }
        if let targetAlbum = targetAlbum {
            albumManager.delete(album: targetAlbum)
        }
        
        // Clean up keychain
        keyManager?.clearKeychainData()
        keyManager = nil
        albumManager = nil
        sourceDiskAccess = nil
        targetDiskAccess = nil
        cancellables = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Delete Tests
    
    func testDeleteSingleMedia() async throws {
        // Create and save test media
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Media should be saved")
        
        // Verify file exists
        let mediaBeforeDelete: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(mediaBeforeDelete.count, 1, "Should have one media item")
        
        // Delete the media
        try await sourceDiskAccess.delete(media: [encryptedMedia!])
        
        // Verify file is deleted
        let mediaAfterDelete: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(mediaAfterDelete.count, 0, "Should have no media items after delete")
    }
    
    func testDeleteMultipleMedia() async throws {
        // Create and save multiple test media
        var savedMedia: [InteractableMedia<EncryptedMedia>] = []
        
        for _ in 0..<3 {
            let testMedia = TestUtils.createTestImageMedia()
            let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
            if let encrypted = try await sourceDiskAccess.save(media: interactableMedia, progress: { _ in }) {
                savedMedia.append(encrypted)
            }
        }
        
        XCTAssertEqual(savedMedia.count, 3, "Should have saved 3 media items")
        
        // Verify all files exist
        let mediaBeforeDelete: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(mediaBeforeDelete.count, 3, "Should have 3 media items")
        
        // Delete all media
        try await sourceDiskAccess.delete(media: savedMedia)
        
        // Verify all files are deleted
        let mediaAfterDelete: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(mediaAfterDelete.count, 0, "Should have no media items after delete")
    }
    
    // MARK: - Move Tests (Current Implementation)
    
    func testMoveWithinSameAlbum() async throws {
        // This tests the current implementation which only moves within the same album
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Media should be saved")
        
        // Try to move within the same album (current implementation)
        try await sourceDiskAccess.move(media: encryptedMedia!)
        
        // Media should still be in the source album
        let mediaAfterMove: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(mediaAfterMove.count, 1, "Media should still be in source album")
    }
    
    func testMoveBetweenAlbums_CurrentImplementation_Fails() async throws {
        // This test demonstrates the current broken implementation
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Media should be saved")
        
        // Verify media is in source album
        let sourceMediaBefore: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(sourceMediaBefore.count, 1, "Should have one media in source")
        
        // Try to move to target album using current implementation
        // This will fail because move() doesn't actually move between albums
        do {
            try await targetDiskAccess.move(media: encryptedMedia!)
            
            // Check results
            let sourceMediaAfter: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
            let targetMediaAfter: [InteractableMedia<EncryptedMedia>] = await targetDiskAccess.enumerateMedia()
            
            // This demonstrates the bug: media is not moved properly
            print("Source media count after 'move': \(sourceMediaAfter.count)")
            print("Target media count after 'move': \(targetMediaAfter.count)")
            
            // The move will likely fail or not work as expected
            XCTFail("Current move implementation doesn't support cross-album moves properly")
            
        } catch {
            // Expected to fail with current implementation
            print("Move failed as expected with error: \(error)")
        }
    }
    
    // MARK: - Proposed Fixed Implementation Tests
    
    func testCopyBetweenAlbums() async throws {
        // Test using copy instead of move for cross-album transfer
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Media should be saved")
        
        // Copy to target album
        try await targetDiskAccess.copy(media: encryptedMedia!)
        
        // Verify media exists in both albums
        let sourceMedia: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        let targetMedia: [InteractableMedia<EncryptedMedia>] = await targetDiskAccess.enumerateMedia()
        
        XCTAssertEqual(sourceMedia.count, 1, "Should still have media in source")
        XCTAssertEqual(targetMedia.count, 1, "Should have media in target")
    }
    
    func testCopyThenDelete_SimulatesMove() async throws {
        // This is how a cross-album move should work: copy then delete
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Media should be saved")
        
        // Step 1: Copy to target album
        try await targetDiskAccess.copy(media: encryptedMedia!)
        
        // Step 2: Delete from source album
        try await sourceDiskAccess.delete(media: [encryptedMedia!])
        
        // Verify media only exists in target album
        let sourceMedia: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        let targetMedia: [InteractableMedia<EncryptedMedia>] = await targetDiskAccess.enumerateMedia()
        
        XCTAssertEqual(sourceMedia.count, 0, "Should have no media in source after move")
        XCTAssertEqual(targetMedia.count, 1, "Should have media in target after move")
    }
    
    // MARK: - UI Integration Tests
    
    func testAlbumDetailViewModelDeleteOperation() async throws {
        // Create view model
        let viewModel = await AlbumDetailViewModel<InteractableMediaDiskAccess>(
            albumManager: albumManager,
            fileManager: sourceDiskAccess,
            album: sourceAlbum,
            purchasedPermissions: DemoPurchasedPermissionManaging(),
            shouldCreateAlbum: false
        )
        
        // Add test media
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }!
        
        // Refresh grid to show media
        await viewModel.gridViewModel.enumerateMedia()
        
        // Select the media
        await MainActor.run {
            viewModel.selectedMedia = Set([encryptedMedia])
            viewModel.isSelectingMedia = true
        }
        
        // Delete selected media
        await viewModel.deleteSelectedMedia()
        
        // Wait a bit for FileOperationBus to trigger grid update
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Verify media is deleted
        await MainActor.run {
            XCTAssertEqual(viewModel.gridViewModel.media.count, 0, "Grid should have no media after delete")
            XCTAssertEqual(viewModel.selectedMedia.count, 0, "Selected media should be cleared")
            XCTAssertFalse(viewModel.isSelectingMedia, "Selection mode should be disabled")
        }
    }
    
    func testAlbumDetailViewModelMoveOperation() async throws {
        // Create a second target album
        let targetAlbum = try albumManager.create(name: "Target Album", storageOption: .local)
        let targetDiskAccess = await InteractableMediaDiskAccess(for: targetAlbum, albumManager: albumManager)
        
        // Create view model
        let viewModel = await AlbumDetailViewModel<InteractableMediaDiskAccess>(
            albumManager: albumManager,
            fileManager: sourceDiskAccess,
            album: sourceAlbum,
            purchasedPermissions: DemoPurchasedPermissionManaging()
        )
        
        // Set up the appModalStateModel
        let appModalStateModel = AppModalStateModel()
        await MainActor.run {
            viewModel.appModalStateModel = appModalStateModel
        }
        
        // Save test media
        let testMedia = TestUtils.createTestImageMedia()
        let interactableMedia = try InteractableMedia(underlyingMedia: [testMedia])
        let encryptedMedia = try await sourceDiskAccess.save(media: interactableMedia) { _ in }
        
        XCTAssertNotNil(encryptedMedia, "Should have saved media")
        
        // Wait for grid to update
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Select media for move
        await MainActor.run {
            viewModel.isSelectingMedia = true
            viewModel.selectedMedia.insert(encryptedMedia!)
        }
        
        // Trigger move modal
        await MainActor.run {
            viewModel.showMoveAlbumModal()
            XCTAssertNotNil(appModalStateModel.currentModal, "Modal should be shown")
            
            // Verify modal context
            if case .albumSelection(let context) = appModalStateModel.currentModal {
                XCTAssertEqual(context.selectedMedia.count, 1, "Should have 1 selected media")
                
                // Filter to find just our target album (since there may be other albums in the test environment)
                let targetAlbumInContext = context.availableAlbums.first { $0.id == targetAlbum.id }
                XCTAssertNotNil(targetAlbumInContext, "Target album should be in available albums")
                
                // Simulate album selection
                context.onAlbumSelected(targetAlbum)
            } else {
                XCTFail("Modal should be album selection type")
            }
        }
        
        // Modal should be dismissed and alert should be shown
        await MainActor.run {
            XCTAssertNil(appModalStateModel.currentModal, "Modal should be dismissed")
            XCTAssertNotNil(viewModel.activeAlert, "Alert should be shown")
            
            // Confirm the move
            if case .moveSelectedMedia(let album) = viewModel.activeAlert {
                XCTAssertEqual(album.id, targetAlbum.id, "Target album should match")
            } else {
                XCTFail("Alert should be move confirmation type")
            }
        }
        
        // Execute the move
        await viewModel.moveSelectedMedia(to: targetAlbum)
        
        // Wait for operations to complete
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second to ensure all async operations complete
        
        // Verify results
        await MainActor.run {
            XCTAssertEqual(viewModel.gridViewModel.media.count, 0, "Source grid should have no media after move")
            XCTAssertEqual(viewModel.selectedMedia.count, 0, "Selected media should be cleared")
            XCTAssertEqual(viewModel.gridViewModel.selectedMedia.count, 0, "Grid view model selected media should be cleared")
            XCTAssertFalse(viewModel.gridViewModel.isSelectingMedia, "Grid view model selection mode should be disabled")
            XCTAssertNotNil(viewModel.activeToast, "Toast should be shown")
            
            if case .mediaMovedSuccess(let count, _) = viewModel.activeToast {
                XCTAssertEqual(count, 1, "Should show 1 item moved")
                // Note: albumName will be the encrypted name, not the original name
            } else {
                XCTFail("Toast should be move success type")
            }
        }
        
        // Verify file was actually moved
        let targetMedia: [InteractableMedia<EncryptedMedia>] = await targetDiskAccess.enumerateMedia()
        XCTAssertEqual(targetMedia.count, 1, "Target album should have 1 media")
        
        let sourceMedia: [InteractableMedia<EncryptedMedia>] = await sourceDiskAccess.enumerateMedia()
        XCTAssertEqual(sourceMedia.count, 0, "Source album should have no media")
    }
}