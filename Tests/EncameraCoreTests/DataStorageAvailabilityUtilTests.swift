import XCTest
@testable import EncameraCore

/// Pins the split between "can this storage be read" and "can a new album go here".
final class DataStorageAvailabilityUtilTests: XCTestCase {

    private var originalContainerSource: iCloudStorageModel.ContainerSource!
    private var originalContainerOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalContainerSource = iCloudStorageModel.containerSource
        originalContainerOverride = iCloudStorageModel.testContainerRootOverride
    }

    override func tearDownWithError() throws {
        iCloudStorageModel.containerSource = originalContainerSource
        iCloudStorageModel.testContainerRootOverride = originalContainerOverride
        try super.tearDownWithError()
    }

    // MARK: - Readability

    func testICloudDriveIsReadableWhenAniCloudAccountIsPresent() throws {
        try skipUnlessAppHosted("reaching the iCloud Drive container needs the app's iCloud entitlement")
        try XCTSkipIf(FileManager.default.ubiquityIdentityToken == nil,
                      "No iCloud account on this host — readability is account-gated.")


        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available)
    }

    /// A signed-in account whose container cannot be reached must not count as
    /// available: every iCloud Drive path needs the container URL.
    func testICloudDriveIsUnavailableWhenTokenPresentButContainerURLNil() {
        iCloudStorageModel.testContainerRootOverride = nil
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { true },
                                                   containerURL: { nil })

        XCTAssertNotEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available)
    }

    func testICloudDriveIsAvailableWhenTokenAndContainerArePresent() {
        iCloudStorageModel.testContainerRootOverride = nil
        let container = FileManager.default.temporaryDirectory
        iCloudStorageModel.containerSource = .init(hasIdentityToken: { true },
                                                   containerURL: { container })

        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud), .available)
    }

    func testLocalStorageStaysReadable() {

        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .local), .available)
    }

    // MARK: - Destination eligibility

    func testICloudDriveIsNotOfferedAsADestination() {

        XCTAssertNotEqual(
            DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud),
            .available
        )
    }

    func testStorageAvailabilitiesHidesICloudDrive() {

        let offered = DataStorageAvailabilityUtil.storageAvailabilities()
            .filter { $0.availability == .available }
            .map(\.storageType)

        XCTAssertFalse(offered.contains(.icloud))
        XCTAssertTrue(offered.contains(.local))
    }

    func testLocalStorageStaysOfferedAsADestination() {

        XCTAssertEqual(
            DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .local),
            .available
        )
    }
}
