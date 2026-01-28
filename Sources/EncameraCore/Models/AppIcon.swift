//
//  AppIcon.swift
//  EncameraCore
//
//  Created for app icon customization feature.
//

import Foundation
import UIKit

/// Enum representing available app icons.
/// Each case represents an icon option with its display name and asset name.
public enum AppIcon: String, CaseIterable, Identifiable {
    case primary = "AppIcon"
    case jazz = "AppIcon-Jazz"
    case calculator = "AppIcon-Calculator"
    case clock = "AppIcon-Clock"
    case compass = "AppIcon-Compass"
    case light = "AppIcon-Light"
    case numbers = "AppIcon-Numbers"
    
    public var id: String { rawValue }
    
    /// The display name shown to users in the icon selection UI.
    public var displayName: String {
        switch self {
        case .primary:
            return L10n.AppIcon.primary
        case .light:
            return L10n.AppIcon.light
        case .jazz:
            return L10n.AppIcon.jazz
        case .calculator:
            return L10n.AppIcon.calculator
        case .clock:
            return L10n.AppIcon.clock
        case .compass:
            return L10n.AppIcon.compass
        case .numbers:
            return L10n.AppIcon.numbers
        }
    }
    
    /// The asset name used to display the icon preview in the selection UI.
    /// This should match the image asset name in Assets.xcassets.
    public var previewAssetName: String {
        switch self {
        case .primary:
            return "AppIconPreview"
        case .jazz:
            return "AppIconPreview-Jazz"
        case .calculator:
            return "AppIconPreview-Calculator"
        case .clock:
            return "AppIconPreview-Clock"
        case .compass:
            return "AppIconPreview-Compass"
        case .light:
            return "AppIconPreview-Light"
        case .numbers:
            return "AppIconPreview-Numbers"
        }
    }
    
    /// The icon name used for UIApplication.setAlternateIconName.
    /// Returns nil for the primary icon (default), or the alternate icon name for others.
    public var iconName: String? {
        self == .primary ? nil : rawValue
    }
    
    /// Whether this is the currently selected app icon.
    public var isSelected: Bool {
        // Get current alternate icon name, nil means primary icon
        let currentIconName = UIApplication.shared.alternateIconName
        return currentIconName == iconName
    }
}
