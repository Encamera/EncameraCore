//
//  EraserUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation

enum ErasureScope {
    case appData
    case allData
}

struct EraserUtils {
    
    var keyManager: KeyManager
    var fileAccess: FileAccess
    var erasureScope: ErasureScope
    
    func erase() async throws {
        switch erasureScope {
        case .appData:
            try await eraseAppData()
        case .allData:
            try await eraseAllData()
        }
    }
    
    private func eraseAllData() async throws {
        try await fileAccess.deleteAllMedia()
        try keyManager.clearKeychainData()
        eraseUserDefaults()
    }
    
    private func eraseAppData() async throws {
        try keyManager.clearKeychainData()
        eraseUserDefaults()
    }
    
    private func eraseUserDefaults() {
        
    }
    
}
