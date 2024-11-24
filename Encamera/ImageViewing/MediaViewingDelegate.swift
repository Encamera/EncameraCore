//
//  MediaViewingDelegate.swift
//  Encamera
//
//  Created by Alexander Freas on 13.08.24.
//

import Foundation
import EncameraCore
import UIKit

protocol MediaViewingDelegate: AnyObject {
    func didView(media: InteractableMedia<EncryptedMedia>)
    func didLoad(media: UIImage, atIndex: Int)
}



