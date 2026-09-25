import XCTest
@testable import EncameraCore

/// Pins the split between "can this storage be read" and "can a new album go here".
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

    /// The deprecation is unconditional, not gated on `cloudKitStorage`. The flag
    /// governs whether CloudKit is *offered*; letting it govern the deprecation too
    /// would keep release builds minting new iCloud Drive albums for as long as the
    /// replacement sits behind the flag.
    func testICloudDriveIsNotOfferedAsADestinationEvenWhenCloudKitIsOff() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: false)

        XCTAssertNotEqual(
            DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud),
            .available
        )
    }

    func testLocalStorageStaysOfferedAsADestination() {
        FeatureToggle.setEnabled(feature: .cloudKitStorage, enabled: true)

        XCTAssertEqual(
            DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .local),
            .available
        )
    }
}
