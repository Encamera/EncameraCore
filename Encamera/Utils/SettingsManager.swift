//
//  SettingsManager.swift
//  Encamera
//
//  Created by Alexander Freas on 17.07.22.
//

import Foundation


enum SettingsValidation: Equatable {
    static func == (lhs: SettingsValidation, rhs: SettingsValidation) -> Bool {
        switch (lhs, rhs) {
        case (.valid, .valid):
            return true
        case (.invalid(let array1), .invalid(let array2)):
            return array1.map { value in
                return array2.contains { pair in
                    return value.key == pair.key && value.message == pair.message
                }
            }.reduce(true) { partialResult, next in
                return partialResult && next
            }
        default:
            return false
        }
    }
    
    case valid
    case invalid([(key: SavedSettings.CodingKeys, message: String)])
}

enum SettingsManagerError: Error, Equatable {
    static func == (lhs: SettingsManagerError, rhs: SettingsManagerError) -> Bool {
        switch (lhs, rhs) {
        case (.couldNotSerialize, .couldNotSerialize):
            return true
        case (.couldNotDeserialize, .couldNotDeserialize):
            return true
        case (.couldNotGetFromUserDefaults, .couldNotGetFromUserDefaults):
            return true
        case (.errorWithBiometrics(let authError1 as AuthManagerError), .errorWithBiometrics(let authError2 as AuthManagerError)):
            return authError1 == authError2
            
        case (.keyManagerError(let keyManagerError1 as KeyManagerError), .keyManagerError(let keyManagerError2 as KeyManagerError)):
            return keyManagerError1 == keyManagerError2
        case (.validationFailed(let validation1), .validationFailed(let validation2)):
            return validation1 == validation2
        default:
            return false
            
            
        }
    }
    
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
    case errorWithBiometrics(Error)
    case keyManagerError(Error)
    case validationFailed(SettingsValidation)
}

struct SavedSettings: Codable, Equatable {
    
    enum CodingKeys: String, CodingKey {
        case useBiometricsForAuth
    }
    
    var useBiometricsForAuth: Bool?
}


struct SettingsManager {
    
    
    private enum Constants {
        static var savedSettingsKey = "savedSettings"
    }

    func loadSettings() throws -> SavedSettings  {
        guard let value = UserDefaults.standard.value(forKey: Constants.savedSettingsKey) as? Data else {
            throw SettingsManagerError.couldNotDeserialize
        }
        return try JSONDecoder().decode(SavedSettings.self, from: value)
    }
    
    func saveSettings(_ settings: SavedSettings) throws {
        
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: Constants.savedSettingsKey)
        } catch {
            throw SettingsManagerError.couldNotSerialize
        }
        
    }
    func validate(_ savedInfo: SavedSettings) throws {
        
        let mirror = Mirror(reflecting: savedInfo)
        var errorKeys = [(SavedSettings.CodingKeys, String)]()
        
        // nil check
        for (property, value) in mirror.children {
            if case Optional<Any>.some(_) = value {
                continue
            } else if let prop = property {
                errorKeys += [(SavedSettings.CodingKeys(rawValue: prop)!, "\(prop) must be set")]
            }
        }
        
        if errorKeys.count > 0 {
            throw SettingsManagerError.validationFailed(SettingsValidation.invalid(errorKeys))
        }
    }
}
