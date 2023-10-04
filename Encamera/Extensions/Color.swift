//
//  Color.swift
//  Encamera
//
//  Created by Alexander Freas on 21.09.22.
//

import Foundation
import SwiftUI

extension Color {
    static var random: Color {
        return Color(
            red: .random(in: 0...1),
            green: .random(in: 0...1),
            blue: .random(in: 0...1)
        )
    }
    static let actionButton = Color("ActionButtonColor")
    static let activeCameraMode = Color("ActiveCameraModeColor")
    static let activeKey = Color("ActiveKeyColor")
    static let foregroundPrimary = Color("ForegroundPrimaryColor")
    static let foregroundSecondary = Color("ForegroundSecondaryColor")
    static let primaryButtonBackground = Color("PrimaryButtonBackgroundColor")
    static let primaryButtonForeground = Color("PrimaryButtonForegroundColor")
    static let background = Color("BackgroundColor")
    static let videoRecordingIndicator = Color("VideoRecordingIndicatorColor")
    static let warningColor = Color("WarningColor")
    static let upgradePillColor = Color("UpgradePillColor")
}
