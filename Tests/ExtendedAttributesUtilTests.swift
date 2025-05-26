//
//  ExtendedAttributesUtilTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on [Date].
//

import XCTest
@testable import EncameraCore
import Foundation

class ExtendedAttributesUtilTests: XCTestCase {
    
    var tempFileURL: URL!
    
    override func setUp() {
        super.setUp()
        // Create a temporary file for testing
        let tempDir = FileManager.default.temporaryDirectory
        tempFileURL = tempDir.appendingPathComponent("test_file_\(UUID().uuidString).txt")
        
        // Create the file
        let testData = "Test file content".data(using: .utf8)!
        try! testData.write(to: tempFileURL)
    }
    
    override func tearDown() {
        // Clean up the temporary file
        try? FileManager.default.removeItem(at: tempFileURL)
        super.tearDown()
    }
    
    func testSetAndGetKeyUUID() throws {
        let testUUID = UUID()
        
        // Set the UUID
        try ExtendedAttributesUtil.setKeyUUID(testUUID, for: tempFileURL)
        
        // Get the UUID back
        let retrievedUUID = try ExtendedAttributesUtil.getKeyUUID(for: tempFileURL)
        
        XCTAssertEqual(testUUID, retrievedUUID, "Retrieved UUID should match the set UUID")
    }
    
    func testGetKeyUUIDFromFileWithoutAttribute() throws {
        // Try to get UUID from a file that doesn't have the attribute
        let retrievedUUID = try ExtendedAttributesUtil.getKeyUUID(for: tempFileURL)
        
        XCTAssertNil(retrievedUUID, "Should return nil for files without the key UUID attribute")
    }
    
    func testRemoveKeyUUID() throws {
        let testUUID = UUID()
        
        // Set the UUID
        try ExtendedAttributesUtil.setKeyUUID(testUUID, for: tempFileURL)
        
        // Verify it's there
        let retrievedUUID = try ExtendedAttributesUtil.getKeyUUID(for: tempFileURL)
        XCTAssertEqual(testUUID, retrievedUUID)
        
        // Remove the UUID
        try ExtendedAttributesUtil.removeKeyUUID(for: tempFileURL)
        
        // Verify it's gone
        let retrievedAfterRemoval = try ExtendedAttributesUtil.getKeyUUID(for: tempFileURL)
        XCTAssertNil(retrievedAfterRemoval, "UUID should be nil after removal")
    }
    
    func testMultipleUUIDOperations() throws {
        let uuid1 = UUID()
        let uuid2 = UUID()
        
        // Set first UUID
        try ExtendedAttributesUtil.setKeyUUID(uuid1, for: tempFileURL)
        let retrieved1 = try ExtendedAttributesUtil.getKeyUUID(for: tempFileURL)
        XCTAssertEqual(uuid1, retrieved1)
        
        // Overwrite with second UUID
        try ExtendedAttributesUtil.setKeyUUID(uuid2, for: tempFileURL)
        let retrieved2 = try ExtendedAttributesUtil.getKeyUUID(for: tempFileURL)
        XCTAssertEqual(uuid2, retrieved2)
        XCTAssertNotEqual(uuid1, retrieved2)
    }
} 