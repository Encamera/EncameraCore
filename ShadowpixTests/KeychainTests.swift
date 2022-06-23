//
//  KeychainTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 22.06.22.
//

import Foundation
import XCTest
import Combine
@testable import Shadowpix


class KeychainTests: XCTestCase {
    
    var keyManager: MultipleKeyKeychainManager = MultipleKeyKeychainManager(isAuthorized: Just(true).eraseToAnyPublisher())
    
    override func setUp() async throws {
        try? keyManager.clearStoredKeys()
    }

    
    func testStoreMultipleKeys() throws {
        try keyManager.generateNewKey(name: "test1")
        try keyManager.generateNewKey(name: "test2")
        
        let storedKeys = try keyManager.storedKeys()
        
        XCTAssertEqual(storedKeys.count, 2)
        XCTAssertEqual(storedKeys[0].name, "test1")
        XCTAssertEqual(storedKeys[1].name, "test2")
    }
    
    func testSelectCurrentKey() throws {
        try keyManager.generateNewKey(name: "test4")
        try keyManager.generateNewKey(name: "test5")

        try keyManager.setActiveKey("test5")
        
        let activeKey = try keyManager.getActiveKey()
        XCTAssertEqual(activeKey.name, "test5")
        XCTAssertNotNil(activeKey.keyBytes)
    }
    
    func testDeleteKeyByName() throws {
        try keyManager.generateNewKey(name: "test1_key")
        try keyManager.generateNewKey(name: "test2_key")

        try keyManager.deleteKey(by: "test2_key")
        
        let storedKeys = try keyManager.storedKeys()

        XCTAssertEqual(storedKeys.count, 1)
        XCTAssertEqual(storedKeys.first!.name, "test1_key")
    }
    
    
}
