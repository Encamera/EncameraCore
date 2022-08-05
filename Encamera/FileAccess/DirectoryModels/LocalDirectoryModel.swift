//
//  LocalDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

struct LocalDirectoryModel: DirectoryModel {
    var baseURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let filesDirectory = documentsDirectory.appendingPathComponent("data")
        return filesDirectory
    }
    
    var keyName: KeyName
        
    init(keyName: KeyName) {
        self.keyName = keyName
    }
    
    
}
