//
//  DecryptedImage.swift
//  Shadowpix
//
//  Created by Alexander Freas on 28.11.21.
//

import Foundation
import UIKit

struct DecryptedImage: Identifiable {
    
    let image: UIImage
    var id: Int {
        return image.hashValue
    }
    
    init(data: Data) {
        self.image = UIImage(data: data)!
    }
}
