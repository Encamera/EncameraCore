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
    
    public var id: String { rawValue }
    
    /// The display name shown to users in the icon selection UI.
    public var displayName: String {
        switch self {
        case .primary:
            return L10n.AppIcon.primary
        case .jazz:
            return L10n.AppIcon.jazz
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
