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
    case elevated
    case primaryButton
}

extension SurfaceType {
    
    var textColor: Color {
        switch self {
        case .background:
            return Color.foregroundPrimary
        case .elevated:
            return Color.foregroundSecondary
        case .primaryButton:
            return Color.primaryButtonForeground

        }
    }
    
    var foregroundSecondary: Color {
        switch self {
        case .background:
            return Color.background
        case .primaryButton:
            return Color.primaryButtonBackground
        case .elevated:
            return Color.foregroundPrimary
        }
    }
}
