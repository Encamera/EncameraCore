//
//  LocalDeeplinkingUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation
import UIKit

class LocalDeeplinkingUtils {
    
    static func openInFiles<T: MediaDescribing>(media: T) where T.MediaSource == URL {
        guard let url = media.source.driveDeeplink() else {
            debugPrint("Could not create deeplink")
            return
        }
        
        UIApplication.shared.open(url)
    }
    
    static func openKeyContentsInFiles(keyName: KeyName) {
        
        let storageSetting = DataStorageUserDefaultsSetting()
        let model = storageSetting.storageModelFor(keyName: keyName)
        guard let url = model?.baseURL.driveDeeplink() else {
            debugPrint("Could not create deeplink")
            return
        }
        
        UIApplication.shared.open(url)
    }
    
    static func deeplinkFor(key: PrivateKey) -> URL? {
        guard let keyString = key.base64String else {
            return nil
        }
        
        let linkString = "encamera://key/\(keyString)"
        return URL(string: linkString)
    }
}

private extension URL {
    
    func driveDeeplink() -> URL? {
        return URL(string: absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://"))
    }
    
}
