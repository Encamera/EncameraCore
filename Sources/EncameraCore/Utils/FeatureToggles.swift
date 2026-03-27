//
//  FeatureToggles.swift
//  Encamera
//
//  Created by Alexander Freas on 28.10.22.
//

import Foundation

public enum Feature: String, CaseIterable {
    case debugTracking
    case enableTestRevenueCat
    case showFeatureToggles
    case encryptedZipExport
    case showDesignSystem
    case newPaywall
    case editRotation
    case detectDuplicates

    var userDefaultsKey: String {
        return "feature_" +  rawValue
    }

    public var title: String {
        switch self {
        case .debugTracking: return "Debug Tracking"
        case .enableTestRevenueCat: return L10n.FeatureToggles.enableTestRevenueCat
        case .showFeatureToggles: return L10n.FeatureToggles.showFeatureToggles
        case .encryptedZipExport: return L10n.FeatureToggles.encryptedZipExport
        case .showDesignSystem: return L10n.FeatureToggles.showDesignSystem
        case .newPaywall: return L10n.FeatureToggles.newPaywall
        case .editRotation: return L10n.FeatureToggles.editRotation
        case .detectDuplicates: return L10n.FeatureToggles.detectDuplicates
        }
    }

    public var description: String {
        switch self {
        case .debugTracking: return "Intercept analytics events and display them in-app for debugging"
        case .enableTestRevenueCat: return L10n.FeatureToggles.enableTestRevenueCatDescription
        case .showFeatureToggles: return L10n.FeatureToggles.showFeatureTogglesDescription
        case .encryptedZipExport: return L10n.FeatureToggles.encryptedZipExportDescription
        case .showDesignSystem: return L10n.FeatureToggles.showDesignSystemDescription
        case .newPaywall: return L10n.FeatureToggles.newPaywallDescription
        case .editRotation: return L10n.FeatureToggles.editRotationDescription
        case .detectDuplicates: return L10n.FeatureToggles.detectDuplicatesDescription
        }
    }

    public var requiresConfirmation: Bool {
        switch self {
        case .debugTracking, .enableTestRevenueCat:
            return true
        default:
            return false
        }
    }

    public var confirmationTitle: String? {
        switch self {
        case .debugTracking: return "Enable Debug Tracking"
        case .enableTestRevenueCat: return L10n.FeatureToggles.revenuecatToggleTitle
        default: return nil
        }
    }

    public var confirmationMessage: String? {
        switch self {
        case .debugTracking: return "Analytics events will be captured in-app instead of sent to services. Continue?"
        case .enableTestRevenueCat: return L10n.FeatureToggles.revenuecatToggleMessage
        default: return nil
        }
    }
}

public struct FeatureToggle {

    public static func enable(feature: Feature) {
        UserDefaultUtils.set(true, forKey: .featureToggle(feature: feature))
    }

    public static func toggle(feature: Feature) {
        let currentValue = isEnabled(feature: feature)
        setEnabled(feature: feature, enabled: !currentValue)
    }

    public static func setEnabled(feature: Feature, enabled: Bool) {
        UserDefaultUtils.set(enabled, forKey: .featureToggle(feature: feature))
    }

    public static func isEnabled(feature: Feature) -> Bool {
        return UserDefaultUtils.bool(forKey: .featureToggle(feature: feature))
    }

}
