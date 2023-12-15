//
//  EventTracking.swift
//  Encamera
//
//  Created by Alexander Freas on 02.12.23.
//

import Foundation
import MatomoTracker
import PiwikPROSDK
import EncameraCore


//let matomoTracker = MatomoTracker(siteId: "23", baseURL: URL(string: "https://demo2.matomo.org/piwik.php")!)

protocol EventTrackable {
    static func trackCameraButtonPressed()
    static func trackPictureTaken()
    static func trackAppOpened()
    static func trackCreateAlbumButtonPressed()
}

enum PurchaseGoal: Int {
    case yearlyUnlimitedKeysAndPhotos
    case montlyUnlimitedKeysAndPhotos

    init?(id: String) {
        switch id {
        case "subscription.yearly.unlimitedkeysandphotos":
            self = .yearlyUnlimitedKeysAndPhotos
        case "subscription.monthly.unlimitedkeysandphotos":
            self = .montlyUnlimitedKeysAndPhotos
        default:
            return nil
        }
    }
}


class EventTracking {
    private let matomoTracker: MatomoTracker = MatomoTracker(siteId: "1", baseURL: URL(string: "https://encameraapp.matomo.cloud/matomo.php")!)
    private let piwikTracker: PiwikTracker = PiwikTracker.sharedInstance(siteID: "5ed9378f-f689-439c-ba90-694075efc81a", baseURL: URL(string: "https://encamera.piwik.pro/piwik.php")!)!
    static let shared = EventTracking()

    private init() {

    }

    private static func track(category: String, action: String, name: String? = nil, value: Float? = nil) {
        Self.shared.matomoTracker.track(eventWithCategory: category, action: action, name: name, value: value)
        Self.shared.piwikTracker.sendEvent(category: category, action: action, name: name, value: value as NSNumber?, path: nil)
    }

    static func trackAppLaunched() {
        track(category: "app", action: "launched")
    }

    static func trackOpenedCameraFromWidget() {
        track(category: "app", action: "opened_camera_from_widget")
    }

    static func trackCameraButtonPressed() {
        track(category: "camera", action: "button_pressed")
    }

    static func trackMediaTaken(type: CameraMode) {
        track(category: "camera", action: "media_captured", name: type.title)
    }

    static func trackAlbumOpened() {
        track(category: "album", action: "opened")
    }

    static func trackImageViewed() {
        track(category: "media", action: "viewed", name: "image")
    }

    static func trackMovieViewed() {
        track(category: "media", action: "viewed", name: "movie")
    }

    static func trackImageShared() {
        track(category: "image", action: "shared")
    }

    static func trackOnboardingViewReached(view: OnboardingFlowScreen) {
        track(category: "onboarding", action: "view_reached", name: view.rawValue)
    }

    static func trackOnboardingFinished() {
        track(category: "onboarding", action: "finished")
    }

    static func trackPhotoLimitReachedScreenUpgradeTapped(from screen: String) {
        track(category: "photo_limit_reached", action: "upgrade_tapped", name: screen)
    }

    static func trackPhotoLimitReachedScreenDismissed(from screen: String) {
        track(category: "photo_limit_reached", action: "dismissed", name: screen)
    }

    static func trackConfirmStorageTypeSelected(type: StorageType) {
        track(category: "storage_type", action: "selected", name: type.rawValue)
    }

    static func trackShowPurchaseScreen(from screen: String) {
        track(category: "purchase", action: "show", name: screen)
    }

    static func trackPurchaseCompleted(from screen: String, currency: String, amount: Decimal, product: String) {
        track(category: "purchase_completed_\(product.lowercased())", action: product.lowercased(), name: screen)

        guard let goalId = PurchaseGoal(id: product) else {
            return
        }
        let amountAsFloat = NSDecimalNumber(decimal: amount).floatValue
        Self.shared.piwikTracker.sendGoal(ID: "\(goalId.rawValue)", revenue: amount as NSNumber)
        Self.shared.matomoTracker.trackGoal(id: goalId.rawValue, revenue: amountAsFloat)
    }

    static func trackPurchaseScreenDismissed(from screen: String) {
        track(category: "purchase", action: "dismissed", name: screen)
    }

    static func trackPurchaseIncomplete(from screen: String) {
        track(category: "purchase", action: "incomplete", name: screen)
    }

    static func trackAlbumCreated() {
        track(category: "album", action: "created")
    }

    static func trackAppOpened() {
        track(category: "app", action: "opened")
    }

    static func trackCreateAlbumButtonPressed() {
        track(category: "album", action: "create_button_pressed")
    }


}
