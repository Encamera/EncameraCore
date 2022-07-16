//
//  PasswordValidatorTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation
import XCTest
@testable import Shadowpix

class PasswordValidatorTests: XCTestCase {
    
    private let validator = PasswordValidator()
    
    func checkPasswordValid() throws {
        let firstPassword = "q1w2e3r4"
        let secondPassword = "q1w2e3r4"
        
        let result = validator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .valid)
    }
    
    func checkPasswordInvalidDifferent() throws {
        let firstPassword = "q1w2e3r4223"
        let secondPassword = "q1w2e3r4"
        
        let result = validator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .invalidDifferent)
    }
    
    func checkPasswordInvalidTooLong() throws {
        let firstPassword = "1111111111111111111111111111111"
        let secondPassword = "1111111111111111111111111111111"
        
        let result = validator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .invalidTooLong)
    }
    
    func checkPasswordInvalidTooShort() throws {
        let firstPassword = "123"
        let secondPassword = "123"
        let result = validator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .invalidTooShort)

    }
    
}
