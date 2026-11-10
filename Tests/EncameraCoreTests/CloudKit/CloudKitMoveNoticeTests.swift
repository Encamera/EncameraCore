//
//  CloudKitMoveNoticeTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

extension XCTestCase {
    /// Points `CloudKitMoveNotice` at a fresh defaults suite for this test, and
    /// back at the previous one when it ends.
    func isolateCloudKitMoveNotices() {
        let previous = CloudKitMoveNotice.defaults
        let suiteName = "CloudKitMoveNoticeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        CloudKitMoveNotice.defaults = defaults
        addTeardownBlock {
            CloudKitMoveNotice.defaults = previous
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

final class CloudKitMoveNoticeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        isolateCloudKitMoveNotices()
    }

    func testMarkThenReadReturnsKind() {
        CloudKitMoveNotice.markPending(albumID: "a", kind: .upgradedFromICloudDrive)
        XCTAssertEqual(CloudKitMoveNotice.pending(albumID: "a"), .upgradedFromICloudDrive)

        CloudKitMoveNotice.markPending(albumID: "b", kind: .movedFromThisDevice)
        XCTAssertEqual(CloudKitMoveNotice.pending(albumID: "b"), .movedFromThisDevice)
    }

    func testClearRemovesNotice() {
        CloudKitMoveNotice.markPending(albumID: "a", kind: .movedFromThisDevice)
        CloudKitMoveNotice.clear(albumID: "a")
        XCTAssertNil(CloudKitMoveNotice.pending(albumID: "a"))
    }

    func testNoticesAreIndependentPerAlbum() {
        CloudKitMoveNotice.markPending(albumID: "a", kind: .upgradedFromICloudDrive)
        CloudKitMoveNotice.markPending(albumID: "b", kind: .movedFromThisDevice)

        CloudKitMoveNotice.clear(albumID: "a")

        XCTAssertNil(CloudKitMoveNotice.pending(albumID: "a"))
        XCTAssertEqual(CloudKitMoveNotice.pending(albumID: "b"), .movedFromThisDevice)
    }

    func testClearAllRemovesEveryNotice() {
        CloudKitMoveNotice.markPending(albumID: "a", kind: .upgradedFromICloudDrive)
        CloudKitMoveNotice.markPending(albumID: "b", kind: .movedFromThisDevice)

        CloudKitMoveNotice.clearAll()

        XCTAssertNil(CloudKitMoveNotice.pending(albumID: "a"))
        XCTAssertNil(CloudKitMoveNotice.pending(albumID: "b"))
    }

    func testKeyIsTheCloudKitAlbumIDOrTheLocalAlbumID() {
        let key = PrivateKey(keyBytes: [], creationDate: Date())
        let cloudKit = Album(name: "Trip", storageOption: .cloudKit, creationDate: Date(), key: key, albumID: "ck-1")
        let local = Album.localTwin(of: cloudKit)
        let drive = Album(name: "Trip", storageOption: .icloud, creationDate: Date(), key: key)

        XCTAssertEqual(CloudKitMoveNotice.key(for: cloudKit), "ck-1")
        XCTAssertEqual(CloudKitMoveNotice.key(for: local), "Trip_local")
        XCTAssertNil(CloudKitMoveNotice.key(for: drive), "an iCloud Drive album never shows a notice")
    }

    func testCarryMovesTheNoticeToTheNewKey() {
        CloudKitMoveNotice.markPending(albumID: "Old_local", kind: .movedToThisDevice)
        CloudKitMoveNotice.markPending(albumID: "other", kind: .movedFromThisDevice)

        CloudKitMoveNotice.carry(from: "Old_local", to: "New_local")

        XCTAssertNil(CloudKitMoveNotice.pending(albumID: "Old_local"))
        XCTAssertEqual(CloudKitMoveNotice.pending(albumID: "New_local"), .movedToThisDevice)
        XCTAssertEqual(CloudKitMoveNotice.pending(albumID: "other"), .movedFromThisDevice)
    }

    func testCarryWithNoNoticeWritesNothing() {
        CloudKitMoveNotice.carry(from: "Old_local", to: "New_local")
        XCTAssertNil(CloudKitMoveNotice.defaults.dictionary(forKey: CloudKitMoveNotice.storageKey))
    }

    func testNoticeSurvivesAReadFromAnotherDefaultsInstance() {
        CloudKitMoveNotice.markPending(albumID: "a", kind: .upgradedFromICloudDrive)
        let stored = CloudKitMoveNotice.defaults.dictionary(forKey: CloudKitMoveNotice.storageKey) as? [String: String]
        XCTAssertEqual(stored, ["a": "upgradedFromICloudDrive"], "persisted as a plain dictionary of raw values")
    }
}
