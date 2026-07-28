import XCTest
@testable import EncameraCore

/// Pins the split between "can this storage be read" and "can a new album go here".
///
/// Regression: the CloudKit toggle used to make `isStorageTypeAvailable(.icloud)`
/// report unavailable, which silently dropped every existing iCloud Drive album out
/// of `AlbumManager.fetchAlbumsFromSources` (and out of the erase/enumerate paths in
/// `DiskFileAccess`). Deprecating iCloud Drive as a *destination* must not hide the
/// albums a user already has there.
final class DataStorageAvailabilityUtilTests: XCTestCase {

    private var originalToggle: Bool!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalToggle = FeatureToggle.isEnabled(feature: .cloudKitStorage)
    }

    override func tearDownWithError() throws {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: originalToggle)
        try super.tearDownWithError()
    }

    // MARK: - Readability

    func testICloudDriveReadabilityIsIndependentOfTheCloudKitToggle() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)
        let withToggleOff = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud)

        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)
        let withToggleOn = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud)

        // Whether iCloud Drive is readable depends only on the iCloud account, so the
        // two answers must agree regardless of which one this host produces.
        XCTAssertEqual(withToggleOn, withToggleOff)
    }

    func testICloudDriveIsReadableWhenAniCloudAccountIsPresent() throws {
        try XCTSkipIf(FileManager.default.ubiquityIdentityToken == nil,
                      "No iCloud account on this host — readability is account-gated.")

        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)

        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available)
    }

    func testLocalStorageStaysReadableWithTheCloudKitToggleOn() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)

        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .local), .available)
    }

    // MARK: - Destination eligibility

    func testICloudDriveIsNotOfferedAsADestinationWhenCloudKitIsOn() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)

        XCTAssertNotEqual(
            DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud),
            .available
        )
    }

    func testStorageAvailabilitiesHidesICloudDriveWhenCloudKitIsOn() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)

        let offered = DataStorageAvailabilityUtil.storageAvailabilities()
            .filter { $0.availability == .available }
            .map(\.storageType)

        XCTAssertFalse(offered.contains(.icloud))
        XCTAssertTrue(offered.contains(.local))
    }

    func testICloudDriveDestinationTracksReadabilityWhenCloudKitIsOff() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)

        XCTAssertEqual(
            DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud),
            DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud)
        )
    }
}
