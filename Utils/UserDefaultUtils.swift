//
//  UserDefaultUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation
import Combine

struct UserDefaultUtils {
    
    private static var defaults: UserDefaults {
        UserDefaults.standard
    }
    
    private static var defaultsPublisher: AnyPublisher<(UserDefaultKey, Any?), Never> {
        defaultsSubject.eraseToAnyPublisher()
    }
    
    private static var defaultsSubject: PassthroughSubject = PassthroughSubject<(UserDefaultKey, Any?), Never>()
    
    static func increaseInteger(forKey key: UserDefaultKey) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += 1
        set(currentValue, forKey: key)
        
    }
    
    static func publisher(for observedKey: UserDefaultKey) -> AnyPublisher<Any?, Never> {
        return defaultsPublisher.filter { key, value in
            return observedKey == key
        }.map { key, value in
            return value
        }.eraseToAnyPublisher()
    }
    
    static func set(_ value: Any?, forKey key: UserDefaultKey) {
        defaults.set(value, forKey: key.rawValue)
        defaultsSubject.send((key, value))
    }
    
    static func value(forKey key: UserDefaultKey) -> Any? {
        return defaults.value(forKey: key.rawValue)
    }
    
    static func bool(forKey key: UserDefaultKey) -> Bool {
        return defaults.bool(forKey: key.rawValue)
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
