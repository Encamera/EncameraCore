//
//  UIFont.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.24.
//

import Foundation
import UIKit

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let systemFontDescriptor = UIFont.systemFont(ofSize: self.pointSize, weight: weight).fontDescriptor
        return UIFont(descriptor: systemFontDescriptor, size: self.pointSize)
    }
}
