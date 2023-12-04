//
//  SurfaceType.swift
//  Encamera
//
//  Created by Alexander Freas on 03.11.22.
//

import Foundation
import SwiftUI

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
        case .background:
            return .foregroundPrimary

        case .lightBackground:
            return .black
        case .darkBackground:
            return .foregroundPrimary
        case .primaryButton:
            return .primaryButtonForeground
        case .textButton:
            return .actionYellowGreen
        case .selectedStorageButton:
            return .black
        case .secondaryButton:
            return .black
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
        case .textButton:
            return .clear
        case .selectedStorageButton:
            return .white
        case .secondaryButton:
            return .clear
        case .disabledButton:
            return .disabledButtonBackgroundColor
        }
    }
}
