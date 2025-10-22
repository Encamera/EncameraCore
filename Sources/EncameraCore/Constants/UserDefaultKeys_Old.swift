//
//  UserDefaultKeys_Old.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//  NOTE: This is the OLD implementation without iCloud sync - used for testing comparison
//

import Foundation

/// Old implementation of UserDefaultKey - NO iCloud sync functionality
/// This is kept for testing to verify new behavior differs from old
public enum UserDefaultKeyOld {
    
    
    case authenticationPolicy
    case currentKey
    case onboardingState
    case directoryTypeKeyFor(album: Album)
    case savedSettings
    case capturedPhotos
    case featureToggle(feature: Feature)
    case viewGalleryCount
    case reviewRequestedMetric
    case lastVersionReviewRequested
    case hasOpenedAlbum
    case keyTutorialClosed
    case currentAlbumID
    case showCurrentAlbumOnLaunch
    case lockoutEnd
    case launchCountKey
    case lastVersionKey
    case photoAddedCount
    case videoAddedCount
    case widgetOpenCount
    case livePhotosActivated
    case defaultStorageLocation
    case showPushNotificationPrompt
    case isAlbumHidden(name: String)
    case albumCoverImage(albumName: String)
    case passcodeType
    case gridZoomLevel
    case hasCompletedFirstLockout

    var rawValue: String {
        switch self {
        case .directoryTypeKeyFor(let album):
            return "\(UserDefaultKeyOld.directoryPrefix)\(album.name)"
        case .featureToggle(feature: let feature):
            return "featureToggle_\(feature)"
        default:
            return String(describing: self)
        
        }
    }
    
    private static var directoryPrefix: String {
        "encamera.keydirectory."
    }
}

extension UserDefaultKeyOld: Equatable {
    public static func ==(lhs: UserDefaultKeyOld, rhs: UserDefaultKeyOld) -> Bool {
        return lhs.rawValue == rhs.rawValue
    }
}
