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
    static let actionYellowGreen = Color("ActionYellowGreen")
    static let primaryButtonForeground = Color("PrimaryButtonForegroundColor")
    static let background = Color("BackgroundColor")
    static let videoRecordingIndicator = Color("VideoRecordingIndicatorColor")
    static let warningColor = Color("WarningColor")
    static let upgradePillColor = Color("UpgradePillColor")
    static let inputFieldBackgroundColor = Color("InputFieldBackgroundColor")
    static let secondaryElementColor = Color("SecondaryElementColor")
    static let stepIndicatorActive = Color("StepIndicatorActiveColor")
    static let stepIndicatorInactive = Color("StepIndicatorInactiveColor")
    static let purchasePopularForegroundShapeColor = Color("Purchase-PopularForegroundShapeColor")
    static let purchasePopularBackgroundShapeColor = Color("Purchase-PopularBackgroundShapeColor")
    static let notificationBadgeColor = Color("NotificationBadgeColor")
}
/*    static let opacity: Double = 0.20
 static let red: Double = 0.21
 static let green: Double = 0.21
 static let blue: Double = 0.21
*/
