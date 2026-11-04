//
//  NotificationUnreadStateTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

/// The Settings unread dot: lit only when the last successful fetch returned a
/// notification the user has not seen in the list.
final class NotificationUnreadStateTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationUnreadStateTests-\(UUID().uuidString)"
        UserDefaultUtils.current = UserDefaultUtils(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        UserDefaultUtils.current = UserDefaultUtils()
        super.tearDown()
    }

    func testNothingFetchedShowsNoDot() {
        XCTAssertFalse(UserDefaultUtils.hasUnseenNotifications)
    }

    func testAnEmptyFetchShowsNoDot() {
        UserDefaultUtils.recordFetchedNotificationIDs([])

        XCTAssertFalse(UserDefaultUtils.hasUnseenNotifications)
    }

    func testAFetchedNotificationTheUserHasNotSeenShowsTheDot() {
        UserDefaultUtils.recordFetchedNotificationIDs(["a", "b"])

        XCTAssertTrue(UserDefaultUtils.hasUnseenNotifications)
    }

    func testSeeingEveryFetchedNotificationClearsTheDot() {
        UserDefaultUtils.recordFetchedNotificationIDs(["a", "b"])
        UserDefaultUtils.markNotificationsSeen(["a", "b"])

        XCTAssertFalse(UserDefaultUtils.hasUnseenNotifications)
    }

    func testRefetchingTheSameNotificationsKeepsTheDotOff() {
        UserDefaultUtils.recordFetchedNotificationIDs(["a", "b"])
        UserDefaultUtils.markNotificationsSeen(["a", "b"])

        UserDefaultUtils.recordFetchedNotificationIDs(["b", "a"])

        XCTAssertFalse(UserDefaultUtils.hasUnseenNotifications)
    }

    func testANewNotificationInALaterFetchShowsTheDot() {
        UserDefaultUtils.recordFetchedNotificationIDs(["a"])
        UserDefaultUtils.markNotificationsSeen(["a"])

        UserDefaultUtils.recordFetchedNotificationIDs(["a", "c"])

        XCTAssertTrue(UserDefaultUtils.hasUnseenNotifications)
    }

    func testARemovedNotificationNoLongerCountsAsUnseen() {
        UserDefaultUtils.recordFetchedNotificationIDs(["a", "b"])
        UserDefaultUtils.markNotificationsSeen(["a"])

        UserDefaultUtils.recordFetchedNotificationIDs(["a"])

        XCTAssertFalse(UserDefaultUtils.hasUnseenNotifications)
    }

    func testSeenIdsTheRemoteDroppedArePruned() {
        UserDefaultUtils.recordFetchedNotificationIDs(["a", "b"])
        UserDefaultUtils.markNotificationsSeen(["a", "b"])

        UserDefaultUtils.recordFetchedNotificationIDs(["b"])

        XCTAssertEqual(UserDefaultUtils.value(forKey: .seenNotificationIDs) as? [String], ["b"])
    }

    func testTheUnreadStateStaysOnThisDevice() {
        XCTAssertFalse(UserDefaultKey.lastFetchedNotificationIDs.shouldSyncToiCloud)
        XCTAssertFalse(UserDefaultKey.seenNotificationIDs.shouldSyncToiCloud)
    }
}
