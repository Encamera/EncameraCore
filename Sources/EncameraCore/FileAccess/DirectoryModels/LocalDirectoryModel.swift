//
//  LocalDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

struct LocalStorageModel: DataStorageModel {
    static var rootURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]

        return documentsDirectory
    }

    
    var storageType: StorageType {
        .local
    }
    
    var baseURL: URL {
        let preferred = Self.albumsURL.appendingPathComponent(album.encryptedPathComponent)
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        let legacy = Self.rootURL.appendingPathComponent(album.encryptedPathComponent)
        if FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }
    
    var album: Album
}
