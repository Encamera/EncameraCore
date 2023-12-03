//
//  EventTracking.swift
//  Encamera
//
//  Created by Alexander Freas on 02.12.23.
//

import Foundation
import MatomoTracker


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

    static func trackAppOpened() {
        track(event: "App", action: "Opened")
    }

    static func trackCreateAlbumButtonPressed() {
        track(event: "Album", action: "Create Button Pressed")
    }


}
