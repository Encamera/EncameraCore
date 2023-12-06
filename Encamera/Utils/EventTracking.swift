//
//  EventTracking.swift
//  Encamera
//
//  Created by Alexander Freas on 02.12.23.
//

import Foundation
import MatomoTracker
import EncameraCore


//let matomoTracker = MatomoTracker(siteId: "23", baseURL: URL(string: "https://demo2.matomo.org/piwik.php")!)

protocol EventTrackable {
    static func trackCameraButtonPressed()
    static func trackPictureTaken()
    static func trackAppOpened()
    static func trackCreateAlbumButtonPressed()
}

class EventTracking {
    private let tracker: MatomoTracker = MatomoTracker(siteId: "1", baseURL: URL(string: "https://encameraapp.matomo.cloud/matomo.php")!)
    static let shared = EventTracking()

    private init() {

    }

    private static func track(event: String, action: String, name: String? = nil, value: Float? = nil) {
        Self.shared.tracker.track(eventWithCategory: event, action: action, name: name, value: value)
    }

    static func trackCameraButtonPressed() {
        track(event: "Camera", action: "Button Pressed")
    }

    static func trackPictureTaken() {
        track(event: "Camera", action: "Picture Taken")
    }

    static func trackAlbumOpened() {
        track(event: "Album", action: "Opened")
    }

    static func trackImageViewed() {
        track(event: "Image", action: "Viewed")
    }

    static func trackImageShared() {
        track(event: "Image", action: "Shared")
    }

    static func trackOnboardingViewReached(view: OnboardingFlowScreen) {
        track(event: "Onboarding", action: "View Reached", name: view.rawValue)
    }

    static func trackOnboardingFinished() {
        track(event: "Onboarding", action: "Finished")
    }

    static func trackPhotoLimitReachedScreenUpgradeTapped(from screen: String) {
        track(event: "Photo Limit Reached", action: "Upgrade Tapped", name: screen)
    }

    static func trackPhotoLimitReachedScreenDismissed(from screen: String) {
        track(event: "Photo Limit Reached", action: "Dismissed", name: screen)
    }

    static func trackConfirmStorageTypeSelected(type: StorageType) {
        track(event: "Storage Type", action: "Selected", name: type.rawValue)
    }

    static func trackShowPurchaseScreen(from screen: String) {
        track(event: "Purchase", action: "Show", name: screen)
    }

    static func trackPurchaseCompleted(from screen: String) {
        track(event: "Purchase", action: "Completed", name: screen)
    }

    static func trackPurchaseIncomplete(from screen: String) {
        track(event: "Purchase", action: "Incomplete", name: screen)
    }

    static func trackAlbumCreated() {
        track(event: "Album", action: "Created")
    }


    static func trackAppOpened() {
        track(event: "App", action: "Opened")
    }

    static func trackCreateAlbumButtonPressed() {
        track(event: "Album", action: "Create Button Pressed")
    }


}
