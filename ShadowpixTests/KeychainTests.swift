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
        let key = try keyManager.generateNewKey(name: "test2_key")

        try keyManager.deleteKey(key)
        
        let storedKeys = try keyManager.storedKeys()

        XCTAssertEqual(storedKeys.count, 1)
        XCTAssertEqual(storedKeys.first!.name, "test1_key")
    }
    
    func testGenerateNewKeySetsCurrentKey() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key")

        XCTAssertEqual(keyManager.currentKey, newKey)
        let activeKey = try XCTUnwrap(keyManager.getActiveKey())
        XCTAssertEqual(activeKey, newKey)
    }
    
    func testGenerateNewKeySetsCurrentKeyInUserDefaults() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key")

        XCTAssertEqual(keyManager.currentKey, newKey)
        let activeKey = try XCTUnwrap(UserDefaults.standard.value(forKey: "currentKey") as? String)
        XCTAssertEqual(activeKey, newKey.name)
    }
    
    func testGenerateNewKeySetsActiveKeyWithoutUserDefaults() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key")
        UserDefaults.standard.removeObject(forKey: "currentKey")
        let activeKey = try XCTUnwrap(keyManager.getActiveKey())
        XCTAssertEqual(activeKey, newKey)
    }
    
    func testDeleteKeyUnsetsCurrentKey() throws {
        let newKey = try keyManager.generateNewKey(name: "test1_key")

        try keyManager.deleteKey(newKey)
        
        XCTAssertNil(keyManager.currentKey)
        XCTAssertThrowsError(try keyManager.getActiveKey())
    }
    
    func testGenerateMutipleNewKeysSetsFirstKeyAsCurrentKey() throws {
        
        let newKey = try keyManager.generateNewKey(name: "test1_key")
        try keyManager.generateNewKey(name: "test2_key")
        XCTAssertEqual(keyManager.currentKey, newKey)
        let activeKey = try XCTUnwrap(keyManager.getActiveKey())
        XCTAssertEqual(activeKey, newKey)
    }
    
    func testGeneratingNewKeyWithExistingNameThrowsError() throws {
        try keyManager.generateNewKey(name: "test1_key")
        XCTAssertThrowsError(try keyManager.generateNewKey(name: "test1_key"))
        
    }
    
    func testInitSetsCurrentKeyIfAuthorized() throws {
        
        let key = try keyManager.generateNewKey(name: "test1_key")
        try keyManager.setActiveKey(key.name)
        let subject = PassthroughSubject<Bool, Never>()
        let newManager = MultipleKeyKeychainManager(isAuthorized: subject.eraseToAnyPublisher())
        subject.send(true)
        
        XCTAssertEqual(newManager.currentKey, key)
        
    }
    
    func testInitDoesNotSetCurrentKeyIfNotAuthorized() throws {
        
        try keyManager.generateNewKey(name: "test1_key")

        let newManager = MultipleKeyKeychainManager(isAuthorized: Just(false).eraseToAnyPublisher())
        
        XCTAssertNil(newManager.currentKey)
        
    }

}
