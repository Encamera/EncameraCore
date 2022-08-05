//
//  ImageKeyDirectoryStorage.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

struct ImageKeyDirectoryStorage {
    
    private enum Constants {
        static func directoryTypeKeyFor(keyName: KeyName) -> String {
            return "encamera.keydirectory.\(keyName)"
        }
    }
    
    static func directoryModelFor(keyName: KeyName) throws -> DirectoryModel {
        
        guard let directoryModelString = UserDefaults.standard.value(forKey: Constants.directoryTypeKeyFor(keyName: keyName)) as? String, let type = DirectoryModelType(rawValue: directoryModelString) else {
            return LocalDirectoryModel(keyName: keyName)
        }
        
        let model = type.modelForType.init(keyName: keyName)
        
        return model
    }
    
    static func setDirectoryModelFor(keyName: KeyName, directoryModelType: DirectoryModelType) throws {
        
        
        UserDefaults.standard.set(directoryModelType.rawValue, forKey: Constants.directoryTypeKeyFor(keyName: keyName))
        
        
    }
}
