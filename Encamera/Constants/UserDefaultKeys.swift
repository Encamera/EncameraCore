//
//  UserDefaultKeys.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

enum UserDefaultKey {
    
    
    case authenticationPolicy
    case currentKey
    case onboardingState
    case directoryTypeKeyFor(keyName: KeyName)
    case savedSettings
    
    var rawValue: String {
        switch self {
        case .directoryTypeKeyFor(let keyName):
            return "encamera.keydirectory.\(keyName)"
        default:
            return String(describing: self)
        
        }
    }
}
