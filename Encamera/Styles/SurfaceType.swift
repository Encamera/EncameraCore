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
    case textButton
    case selectedStorageButton
}

extension SurfaceType {
    
    var textColor: Color {
        switch self {
        case .background:
            return .foregroundPrimary
        case .elevated:
            return .foregroundSecondary
        case .primaryButton:
            return .primaryButtonForeground
        case .textButton:
            return .actionYellowGreen
        case .selectedStorageButton:
            return .black
        }
    }
    
    var foregroundSecondary: Color {
        switch self {
        case .background:
            return .background
        case .primaryButton:
            return .actionYellowGreen
        case .elevated:
            return .foregroundPrimary
        case .textButton:
            return .clear
        case .selectedStorageButton:
            return .white
        }
    }
}
