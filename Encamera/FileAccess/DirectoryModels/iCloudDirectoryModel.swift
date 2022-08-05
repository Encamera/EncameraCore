//
//  iCloudDirectoryModel.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation

struct iCloudFilesDirectoryModel: DirectoryModel {
    
    
    let keyName: KeyName
    
    var baseURL: URL {
        guard let driveURL = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") else {
            fatalError("Could not get drive url")
        }
        
        let destURL = driveURL.appendingPathComponent(keyName)
        return destURL
    }
}
