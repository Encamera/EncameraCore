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
        UserDefaults.standard.removeObject(forKey: "savedSettings")
    }
    
    func testEqualityOfSettingsValidationValid() throws {
        XCTAssertEqual(SettingsValidation.valid, SettingsValidation.valid)
    }
    
    func testEqualityOfSettingsValidationInvalid() throws {
        XCTAssertEqual(
            SettingsValidation.invalid([(SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth")]),
            SettingsValidation.invalid([(SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth")])
        )
    }
    
    func testSaveSettings() async throws {
        let settings = SavedSettings(useBiometricsForAuth: true)
        
        try await manager.saveSettings(settings)
    }
    
    func testValidationValid() throws {
        let settings = SavedSettings(useBiometricsForAuth: true)

        try manager.validate(settings)
    }
    
    func testValidationThrowsInvalidWhenNil() throws {
        let settings = SavedSettings(useBiometricsForAuth: nil)

        XCTAssertThrowsError(try manager.validate(settings), "settings validation") { error in
            
            guard let validation = error as? SettingsManagerError else {
                XCTFail("Invalid error")
                return
            }
            
            guard case .validationFailed(let validated) = validation else {
                return
                
            }

            
            XCTAssertEqual(
                SettingsValidation.invalid([
                    (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")                ]),
                validated
            )
        }
    }

}
