//
//  ShadowPixImage.swift
//  Shadowpix
//
//  Created by Alexander Freas on 29.11.21.
//

import Foundation
import UIKit
import SwiftUI

class ShadowPixMedia: ObservableObject, Identifiable {
    
    @Published var decryptedImage: DecryptedImage?
    var url: URL
    
    init(url: URL) {
        self.url = url
    }
}

extension ShadowPixMedia {
    func loadImage() {
        #if targetEnvironment(simulator)
        decryptedImage = DecryptedImage(image: UIImage(systemName: "lock")!)
        #else
        decryptedImage = iCloudFilesManager.getImageAt(url: url)
        #endif
        
    }
}
