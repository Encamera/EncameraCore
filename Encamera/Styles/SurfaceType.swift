//
//  SurfaceType.swift
//  Encamera
//
//  Created by Alexander Freas on 03.11.22.
//

import Foundation
import SwiftUI
import UIKit

enum SurfaceType {
    case background
    case lightBackground
    case darkBackground
    case primaryButton
    case secondaryButton
    case textButton
    case selectedStorageButton
    case disabledButton
}

extension SurfaceType {
    var textColor: Color {
        switch self {
        case .background, .darkBackground:
            return .foregroundPrimary
        case .lightBackground, .selectedStorageButton, .secondaryButton:
            return .black
        case .primaryButton:
            return .primaryButtonForeground
        case .textButton:
            return .actionYellowGreen
        case .disabledButton:
            return .disabledButtonTextColor
        }
    }

    var textUIColor: UIColor {
        switch self {
        case .background, .darkBackground:
            return .foregroundPrimary
        case .lightBackground, .selectedStorageButton, .secondaryButton:
            return .black
        case .primaryButton:
            return .primaryButtonForeground
        case .textButton:
            return .actionYellowGreen
        case .disabledButton:
            return .disabledButtonTextColor
        }
    }

    var foregroundSecondary: Color {
        switch self {
        case .background:
            return .background
        case .lightBackground:
            return .white
        case .primaryButton:
            return .actionYellowGreen
        case .darkBackground:
            return .foregroundPrimary
        case .textButton, .secondaryButton:
            return .clear
        case .selectedStorageButton:
            return .white
        case .disabledButton:
            return .disabledButtonBackgroundColor
        }
    }

    var foregroundSecondaryUIColor: UIColor {
        switch self {
        case .background:
            return .background
        case .lightBackground:
            return .white
        case .primaryButton:
            return .actionYellowGreen
        case .darkBackground:
            return .foregroundPrimary
        case .textButton, .secondaryButton:
            return .clear
        case .selectedStorageButton:
            return .white
        case .disabledButton:
            return .disabledButtonBackgroundColor
        }
    }

    // Adding UIFont property
    var uiFont: UIFont {
        return font.toUIFont()
    }

    // Keeping the original SwiftUI font property
    var font: Font {
        switch self {
        case .background, .darkBackground, .lightBackground:
            return .body
        case .primaryButton:
            return .headline
        case .secondaryButton, .textButton, .selectedStorageButton, .disabledButton:
            return .subheadline
        }
    }
}

// Extension to convert SwiftUI Font to UIFont
extension Font {
    func toUIFont() -> UIFont {
        switch self {
        case .largeTitle:
            return UIFont.preferredFont(forTextStyle: .largeTitle)
        case .title:
            return UIFont.preferredFont(forTextStyle: .title1)
        case .title2:
            return UIFont.preferredFont(forTextStyle: .title2)
        case .title3:
            return UIFont.preferredFont(forTextStyle: .title3)
        case .headline:
            return UIFont.preferredFont(forTextStyle: .headline)
        case .subheadline:
            return UIFont.preferredFont(forTextStyle: .subheadline)
        case .body:
            return UIFont.preferredFont(forTextStyle: .body)
        case .callout:
            return UIFont.preferredFont(forTextStyle: .callout)
        case .footnote:
            return UIFont.preferredFont(forTextStyle: .footnote)
        case .caption:
            return UIFont.preferredFont(forTextStyle: .caption1)
        case .caption2:
            return UIFont.preferredFont(forTextStyle: .caption2)
        default:
            return UIFont.systemFont(ofSize: 17) // Default font size
        }
    }
}
