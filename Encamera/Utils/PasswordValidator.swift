//
//  PasswordValidator.swift
//  Encamera
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation


enum PasswordValidation {
    case notDetermined
    case valid
    case invalidTooShort
    case invalidDifferent
    case invalidTooLong
    
    var validationDescription: String {
        switch self {
        case .notDetermined:
            return "Not determined."
        case .valid:
            return "Password is valid."
        case .invalidTooShort:
            return "Password is too short, <\(PasswordValidation.minPasswordLength)"
        case .invalidDifferent:
            return "Passwords do not match."
        case .invalidTooLong:
            return "Password is too long, >\(PasswordValidation.maxPasswordLength)"
            
        }
    }
    
    static let minPasswordLength = 4
    static let maxPasswordLength = 30
}

struct PasswordValidator {
    func validate(password: String) -> PasswordValidation {
        let validationState: PasswordValidation
        switch (password) {
        case password where password.count > PasswordValidation.maxPasswordLength:
            validationState = .invalidTooLong
        case password where password.count <= PasswordValidation.minPasswordLength:
            validationState = .invalidTooShort
        default:
            validationState = .valid
        }
        return validationState

    }
    
    func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        let validationState: PasswordValidation
        switch (password1, password2) {
        case (password2, password1):
            return validate(password: password1)
        default:
            validationState = .invalidDifferent
        }
        return validationState
    }
}
