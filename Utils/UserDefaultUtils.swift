//
//  UserDefaultUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation
import Combine

public struct UserDefaultUtils {
    
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.me.freas.encamera")!
    }
    
    private static var defaultsPublisher: AnyPublisher<(UserDefaultKey, Any?), Never> {
        defaultsSubject.eraseToAnyPublisher()
    }
    
    private static var defaultsSubject: PassthroughSubject = PassthroughSubject<(UserDefaultKey, Any?), Never>()
    
    public init() {}
    
    public static func increaseInteger(forKey key: UserDefaultKey) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += 1
        set(currentValue, forKey: key)
        
    }
    
    public static func publisher(for observedKey: UserDefaultKey) -> AnyPublisher<Any?, Never> {
        return defaultsPublisher.filter { key, value in
            return observedKey == key
        }.map { key, value in
            return value
        }.eraseToAnyPublisher()
    }
    
    public static func set(_ value: Any?, forKey key: UserDefaultKey) {
        defaults.set(value, forKey: key.rawValue)
        defaultsSubject.send((key, value))
    }
    
    public static func value(forKey key: UserDefaultKey) -> Any? {
        return defaults.value(forKey: key.rawValue)
    }
    
    public static func bool(forKey key: UserDefaultKey) -> Bool {
        return defaults.bool(forKey: key.rawValue)
    }
    
    public static func removeObject(forKey key: UserDefaultKey) {
        return defaults.removeObject(forKey: key.rawValue)
    }
    
    public static func data(forKey key: UserDefaultKey) -> Data? {
        defaults.data(forKey: key.rawValue)
    }
    
    public static func removeAll() {
        defaults.dictionaryRepresentation().keys.forEach { key in
            defaults.removeObject(forKey: key)
        }
    }
    
}
