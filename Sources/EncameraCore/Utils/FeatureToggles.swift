//
//  FeatureToggles.swift
//  Encamera
//
//  Created by Alexander Freas on 28.10.22.
//

import Foundation

public enum Feature: String, CaseIterable {
    case enableVideo
    case stopTracking
    case recoveryPhrase
    case hideAlbum
    case enableTestRevenueCat
    case showFeatureToggles
    case showMoveToAlbum
    case encryptedZipExport
    case showDesignSystem
    case debugRemoteContent
    case appIconSelection
    case writeV2Metadata
    case newPaywall

    var userDefaultsKey: String {
        return "feature_" +  rawValue
    }
    
    public var title: String {
        switch self {
        case .enableVideo: return L10n.FeatureToggles.enableVideo
        case .stopTracking: return L10n.FeatureToggles.stopTracking
        case .recoveryPhrase: return L10n.FeatureToggles.recoveryPhrase
        case .hideAlbum: return L10n.FeatureToggles.hideAlbum
        case .enableTestRevenueCat: return L10n.FeatureToggles.enableTestRevenueCat
        case .showFeatureToggles: return L10n.FeatureToggles.showFeatureToggles
        case .showMoveToAlbum: return L10n.FeatureToggles.showMoveToAlbum
        case .encryptedZipExport: return L10n.FeatureToggles.encryptedZipExport
        case .showDesignSystem: return L10n.FeatureToggles.showDesignSystem
        case .debugRemoteContent: return L10n.FeatureToggles.debugRemoteContent
        case .appIconSelection: return L10n.FeatureToggles.appIconSelection
        case .writeV2Metadata: return L10n.FeatureToggles.writeV2Metadata
        case .newPaywall: return L10n.FeatureToggles.newPaywall
        }
    }

    public var description: String {
        switch self {
        case .enableVideo: return L10n.FeatureToggles.enableVideoDescription
        case .stopTracking: return L10n.FeatureToggles.stopTrackingDescription
        case .recoveryPhrase: return L10n.FeatureToggles.recoveryPhraseDescription
        case .hideAlbum: return L10n.FeatureToggles.hideAlbumDescription
        case .enableTestRevenueCat: return L10n.FeatureToggles.enableTestRevenueCatDescription
        case .showFeatureToggles: return L10n.FeatureToggles.showFeatureTogglesDescription
        case .showMoveToAlbum: return L10n.FeatureToggles.showMoveToAlbumDescription
        case .encryptedZipExport: return L10n.FeatureToggles.encryptedZipExportDescription
        case .showDesignSystem: return L10n.FeatureToggles.showDesignSystemDescription
        case .debugRemoteContent: return L10n.FeatureToggles.debugRemoteContentDescription
        case .appIconSelection: return L10n.FeatureToggles.appIconSelectionDescription
        case .writeV2Metadata: return L10n.FeatureToggles.writeV2MetadataDescription
        case .newPaywall: return L10n.FeatureToggles.newPaywallDescription
        }
    }
    
    public var requiresConfirmation: Bool {
        switch self {
        case .stopTracking, .enableTestRevenueCat:
            return true
        default:
            return false
        }
    }
    
    public var confirmationTitle: String? {
        switch self {
        case .stopTracking: return L10n.FeatureToggles.stopTrackingToggleTitle
        case .enableTestRevenueCat: return L10n.FeatureToggles.revenuecatToggleTitle
        default: return nil
        }
    }
    
    public var confirmationMessage: String? {
        switch self {
        case .stopTracking: return L10n.FeatureToggles.stopTrackingToggleMessage
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
