//
//  FeatureToggles.swift
//  Encamera
//
//  Created by Alexander Freas on 28.10.22.
//

import Foundation

enum Feature: String {
    case enableVideo
    
    var userDefaultsKey: String {
        return "feature_" +  rawValue
    }
}

struct FeatureToggle {
    
    static func enable(feature: Feature) {
        UserDefaultUtils.set(true, forKey: .featureToggle(feature: feature))
    }
    
    static func isEnabled(feature: Feature) -> Bool {
        return UserDefaultUtils.bool(forKey: .featureToggle(feature: feature))
    }
    
}
