//
//  ImageKeyDirectoryStorage.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

protocol DataStorageSetting {
    func storageModelFor(keyName: KeyName) -> DataStorageModel
    func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType)
}

struct ImageKeyDirectoryStorage: DataStorageSetting {
    
    private enum Constants {
        static func directoryTypeKeyFor(keyName: KeyName) -> String {
            return "encamera.keydirectory.\(keyName)"
        }
    }
    
    func storageModelFor(keyName: KeyName) -> DataStorageModel {
        
        guard let directoryModelString = UserDefaults.standard.value(forKey: Constants.directoryTypeKeyFor(keyName: keyName)) as? String, let type = StorageType(rawValue: directoryModelString) else {
            return LocalStorageModel(keyName: keyName)
        }
        
        let model = type.modelForType.init(keyName: keyName)
        
        return model
    }
    
    func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType) {
        
        
        UserDefaults.standard.set(directoryModelType.rawValue, forKey: Constants.directoryTypeKeyFor(keyName: keyName))
        
        
    }
}
