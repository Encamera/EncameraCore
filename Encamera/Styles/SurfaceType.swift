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
}

extension SurfaceType {
    
    var textColor: Color {
        switch self {
        case .background:
            return Color.primaryButtonForeground
        case .elevated:
            return Color.foregroundSecondary
        }
    }
    
    var foregroundSecondary: Color {
        switch self {
        case .background:
            return Color.primaryButtonBackground
        case .elevated:
            return Color.foregroundPrimary
        }
    }
}
