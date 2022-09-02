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

extension DataStorageSetting {
    
    func isStorageTypeAvailable(type: StorageType) -> StorageType.Availability {
        switch type {
        case .icloud:
            if FileManager.default.ubiquityIdentityToken == nil {
                return .unavailable(reason: "No iCloud account found on this device.")
            } else {
                return .available
            }
        case .local:
            return .available
        }
    }
}

struct DataStorageUserDefaultsSetting: DataStorageSetting {
    
    private enum Constants {
        static func directoryTypeKeyFor(keyName: KeyName) -> String {
            return "encamera.keydirectory.\(keyName)"
        }
    }
    
    func storageModelFor(keyName: KeyName) -> DataStorageModel {
        
        guard let directoryModelString = UserDefaults.standard.value(forKey: Constants.directoryTypeKeyFor(keyName: keyName)) as? String,
              let type = StorageType(rawValue: directoryModelString) else {
            let model = determineStorageModelFor(keyName: keyName)
            setStorageTypeFor(keyName: keyName, directoryModelType: model.storageType)
            return model
        }
        
        let model = type.modelForType.init(keyName: keyName)
        
        return model
    }
    
    func determineStorageModelFor(keyName: KeyName) -> DataStorageModel {
        
        let local = LocalStorageModel(keyName: keyName)
        if FileManager.default.fileExists(atPath: local.baseURL.path) {
            return local
        }
        
        guard case .available = isStorageTypeAvailable(type: .icloud) else {
            return local
        }
        
        let remote = iCloudStorageModel(keyName: keyName)
        _ = remote.baseURL.startAccessingSecurityScopedResource()
        defer {
            remote.baseURL.stopAccessingSecurityScopedResource()
        }
        if FileManager.default.fileExists(atPath: remote.baseURL.path) {
            return remote
        }
        return local
    }
    
    func setStorageTypeFor(keyName: KeyName, directoryModelType: StorageType) {
            
        UserDefaults.standard.set(directoryModelType.rawValue, forKey: Constants.directoryTypeKeyFor(keyName: keyName))
        
    }
}
