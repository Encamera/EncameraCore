//
//  StorageType.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation


enum StorageType: String {
    case icloud
    case local
    
    enum Availability {
        case available
        case unavailable(reason: String)
    }
    
    var modelForType: DataStorageModel.Type {
        switch self {
        case .icloud:
            return iCloudStorageModel.self
        case .local:
            return LocalStorageModel.self
        }
    }
    
}

extension StorageType: Identifiable, CaseIterable {
    var id: Self { self }
    var title: String {
        switch self {
        case .icloud:
            return "iCloud"
        case .local:
            return "Local"
        }
    }
    
    var iconName: String {
        switch self {
        case .icloud:
            return "lock.icloud"
        case .local:
            return "lock.iphone"
        }
    }
    
    var description: String {
        switch self {
        case .icloud:
            return "Saves encrypted files to iCloud Drive."
        case .local:
            return "Saves encrypted files to this device."
        }
    }
    
}
