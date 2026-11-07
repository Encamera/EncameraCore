//
//  ICloudDriveBlobMigrationCellularPreferenceTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

/// The switch that lets the iCloud Drive blob migration use cellular: off by
/// default, which networks it opens, and that only the blob migration's
/// CloudKit requests read it.
final class ICloudDriveBlobMigrationCellularPreferenceTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ICloudDriveBlobMigrationCellularPreferenceTests-\(UUID().uuidString)"
        UserDefaultUtils.current = UserDefaultUtils(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        UserDefaultUtils.current = UserDefaultUtils()
        super.tearDown()
    }

    func testOffByDefault() {
        XCTAssertFalse(ICloudDriveBlobMigrationCellularPreference.isAllowed)
        XCTAssertFalse(ICloudDriveBlobMigration.requestPolicy.allowsCellularAccess)
    }

    func testStoredLocallyAndNeverSynced() {
        ICloudDriveBlobMigrationCellularPreference.isAllowed = true

        XCTAssertTrue(UserDefaultUtils.current.defaults.bool(forKey: UserDefaultKey.useCellularForICloudDriveBlobMigration.rawValue))
        XCTAssertFalse(UserDefaultKey.useCellularForICloudDriveBlobMigration.shouldSyncToiCloud)
    }

    func testChangePostsOnceAndRepeatPostsNothing() {
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: ICloudDriveBlobMigrationCellularPreference.didChange,
                                                           object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        ICloudDriveBlobMigrationCellularPreference.isAllowed = true
        ICloudDriveBlobMigrationCellularPreference.isAllowed = true
        XCTAssertEqual(posts, 1)

        ICloudDriveBlobMigrationCellularPreference.isAllowed = false
        XCTAssertEqual(posts, 2)
    }

    func testPermitsTransfer() {
        let wifi = NetworkMonitor.ForcedPath.wifi.state
        let cellular = NetworkMonitor.ForcedPath.cellular.state
        let offline = NetworkMonitor.State.offline

        XCTAssertTrue(ICloudDriveBlobMigrationCellularPreference.permitsTransfer(on: wifi, cellularAllowed: false))
        XCTAssertFalse(ICloudDriveBlobMigrationCellularPreference.permitsTransfer(on: cellular, cellularAllowed: false))
        XCTAssertTrue(ICloudDriveBlobMigrationCellularPreference.permitsTransfer(on: cellular, cellularAllowed: true))
        XCTAssertFalse(ICloudDriveBlobMigrationCellularPreference.permitsTransfer(on: offline, cellularAllowed: true),
                       "allowing cellular never makes an offline device count as connected")
    }

    /// The blob migration's requests follow the preference and keep the speed-up
    /// policy's quality of service.
    func testAllowedPreferenceLetsBlobMigrationRequestsUseCellular() {
        let savedPolicy = ICloudDriveBlobMigration.networkPolicy
        defer { ICloudDriveBlobMigration.networkPolicy = savedPolicy }
        ICloudDriveBlobMigrationCellularPreference.isAllowed = true

        for policy in [CloudKitNetworkPolicy.background, .speedUp] {
            ICloudDriveBlobMigration.networkPolicy = policy
            XCTAssertTrue(ICloudDriveBlobMigration.requestPolicy.allowsCellularAccess)
            XCTAssertEqual(ICloudDriveBlobMigration.requestPolicy.qualityOfService, policy.qualityOfService)
        }
    }

    /// The folder walk and the whole-album move use `makeMigrationStore`, which
    /// stays Wi-Fi only whatever the preference says.
    func testAllowedPreferenceLeavesOtherWiFiOnlyStoresAlone() {
        ICloudDriveBlobMigrationCellularPreference.isAllowed = true

        XCTAssertFalse(CloudKitNetworkPolicy.background.allowsCellularAccess)
        XCTAssertFalse(CloudKitNetworkPolicy.speedUp.allowsCellularAccess)
        XCTAssertFalse(ICloudDriveBlobMigration.networkPolicy.allowsCellularAccess)
    }
}
