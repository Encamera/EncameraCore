//
//  File.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 14.11.21.
//

import Foundation
import XCTest
@testable import Shadowpix

class ChaChaPolyHelperTests: XCTestCase {
    
    
    override class func setUp() {
        WorkWithKeychain.clearKeychain()
    }
    
    override class func tearDown() {
        WorkWithKeychain.clearKeychain()
    }
    
    func testSaveKey() throws {
        
        try ChaChaPolyHelpers.generateNewKey(name: "testkey")
        
        let key = WorkWithKeychain.getKeyObject()
        
        XCTAssertEqual(key!.name, "testkey")
        
    }
}
