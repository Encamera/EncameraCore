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
            await eraseAppData()
        case .allData:
            await eraseAllData()
        }
    }
    
    private func eraseAllData() async {
        try? await fileAccess.deleteAllMedia()
        keyManager.clearKeychainData()
        eraseUserDefaults()
    }
    
    private func eraseAppData() async {
        keyManager.clearKeychainData()
        eraseUserDefaults()
    }
    
    private func eraseUserDefaults() {
        
    }
    
}
