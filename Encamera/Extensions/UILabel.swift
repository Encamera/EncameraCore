//
//  UILabel.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.24.
//

import Foundation
import UIKit

extension UILabel {
    func applyFontType(_ fontType: EncameraFont, on surface: SurfaceType = .background, weight: UIFont.Weight = .regular) {
        self.font = fontType.uiFont.withWeight(weight)
        self.textColor = surface.textUIColor
    }
}

extension UIButton {
    func applyFontType(_ fontType: EncameraFont, on surface: SurfaceType = .background, weight: UIFont.Weight = .regular) {
        self.titleLabel?.font = fontType.uiFont.withWeight(weight)
        self.setTitleColor(surface.textUIColor, for: .normal)
    }
}
