//
//  UserDefaultUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

struct UserDefaultUtils {
    
    static var defaults: UserDefaults {
        UserDefaults.standard
    }
    
    static func set(_ value: Any?, forKey key: UserDefaultKey) {
        defaults.set(value, forKey: key.rawValue)
    }
    
    static func value(forKey key: UserDefaultKey) -> Any? {
        return defaults.value(forKey: key.rawValue)
    }
    
    static func removeObject(forKey key: UserDefaultKey) {
        return defaults.removeObject(forKey: key.rawValue)
    }
    
    static func data(forKey key: UserDefaultKey) -> Data? {
        defaults.data(forKey: key.rawValue)
    }
    
    static func removeAll() {
        defaults.dictionaryRepresentation().keys.forEach { key in
            defaults.removeObject(forKey: key)
        }
    }
    
}
