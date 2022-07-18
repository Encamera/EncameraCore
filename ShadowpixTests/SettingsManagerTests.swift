//
//  SettingsManagerTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 18.07.22.
//

import Foundation
import XCTest
@testable import Shadowpix

class SettingsManagerTests: XCTestCase {
    
    private var manager: SettingsManager!
    private var authManager: DemoAuthManager!
    private var keyManager: DemoKeyManager!
    
    override func setUp() async throws {
        self.keyManager = DemoKeyManager()
        self.authManager = DemoAuthManager()
        self.manager = SettingsManager(authManager: authManager, keyManager: keyManager)
    }
    
    func testEqualityOfSettingsValidation() throws {
        
    }
    
}
