import XCTest
@testable import EncameraCore

final class StorageUsageBreakdownTests: XCTestCase {

    /// The data-loss guard, and the reason this type exists: "Free up space" is wired
    /// to `reclaimableBytes`, and `.local` media is the only copy in existence.
    func testReclaimableBytesExcludesLocalMedia() {
        let breakdown = StorageUsageBreakdown(localMediaBytes: 5_000_000)

        XCTAssertEqual(breakdown.reclaimableBytes, 0)
        XCTAssertEqual(breakdown.totalDeviceBytes, 5_000_000)
    }

    /// Every re-fetchable bucket contributes, so adding a bucket later without
    /// updating the accessor fails here rather than under-reporting on screen.
    func testReclaimableBytesSumsEveryRefetchableBucket() {
        let breakdown = StorageUsageBreakdown(
            localMediaBytes: 1_000,
            cachedCloudBytes: 200,
            thumbnailBytes: 30,
            indexBytes: 4
        )

        XCTAssertEqual(breakdown.reclaimableBytes, 234)
        XCTAssertEqual(breakdown.totalDeviceBytes, 1_234)
    }

    func testTotalDeviceBytesNeverLessThanReclaimable() {
        let cases: [StorageUsageBreakdown] = [
            StorageUsageBreakdown(),
            StorageUsageBreakdown(localMediaBytes: 1),
            StorageUsageBreakdown(cachedCloudBytes: 1),
            StorageUsageBreakdown(thumbnailBytes: 1, indexBytes: 1),
            StorageUsageBreakdown(
                localMediaBytes: 900_000_000,
                cachedCloudBytes: 500_000_000,
                thumbnailBytes: 12_345,
                indexBytes: 678,
                cloudBytes: 9_000_000_000
            ),
        ]

        for breakdown in cases {
            XCTAssertLessThanOrEqual(breakdown.reclaimableBytes, breakdown.totalDeviceBytes)
            XCTAssertGreaterThanOrEqual(breakdown.reclaimableBytes, 0)
        }
    }

    /// Pins the overlap semantics: a fully-cached library reports the same
    /// `cloudBytes` it would report cached or not, and the device total counts those
    /// bytes exactly once.
    func testCachedCloudBytesIsNotAddedToCloudBytes() {
        let fullyCached = StorageUsageBreakdown(cachedCloudBytes: 750, cloudBytes: 750)

        XCTAssertEqual(fullyCached.cloudBytes, 750)
        XCTAssertEqual(fullyCached.totalDeviceBytes, 750)

        let nothingCached = StorageUsageBreakdown(cachedCloudBytes: 0, cloudBytes: 750)
        XCTAssertEqual(nothingCached.cloudBytes, fullyCached.cloudBytes)
        XCTAssertEqual(nothingCached.totalDeviceBytes, 0)
    }

    func testUnavailableCloudBytesIsDistinctFromZero() {
        XCTAssertNil(StorageUsageBreakdown().cloudBytes)
        XCTAssertEqual(StorageUsageBreakdown(cloudBytes: 0).cloudBytes, 0)
    }

    // MARK: - Two cloud methods

    func testCloudBytesSumsCloudKitAndICloudDrive() {
        let breakdown = StorageUsageBreakdown(
            cloudKitMedia: MediaTypeBytes(photoBytes: 600, videoBytes: 400),
            iCloudDriveMedia: MediaTypeBytes(photoBytes: 50, videoBytes: 950)
        )

        XCTAssertEqual(breakdown.cloudBytes, 2_000)
        XCTAssertEqual(breakdown.cloudMedia, MediaTypeBytes(photoBytes: 650, videoBytes: 1_350))
        XCTAssertEqual(breakdown.totalDeviceBytes, 0, "Neither method is on this device")
    }

    /// One unknowable method makes the whole cloud figure unknowable: a partial sum
    /// rendered as a total is a lie, not an approximation.
    func testCloudBytesIsNilWhenEitherMethodIsUnknowable() {
        XCTAssertNil(StorageUsageBreakdown(cloudKitMedia: nil, iCloudDriveMedia: .zero).cloudBytes)
        XCTAssertNil(StorageUsageBreakdown(cloudKitMedia: .zero, iCloudDriveMedia: nil).cloudBytes)
        XCTAssertEqual(StorageUsageBreakdown(cloudKitMedia: .zero, iCloudDriveMedia: .zero).cloudBytes, 0)
    }

    func testCloudKitShareOfCloud() {
        let mixed = StorageUsageBreakdown(cloudKitMedia: MediaTypeBytes(photoBytes: 750),
                                          iCloudDriveMedia: MediaTypeBytes(videoBytes: 250))
        XCTAssertEqual(mixed.cloudKitShareOfCloud, 0.75)

        let allCloudKit = StorageUsageBreakdown(cloudKitMedia: MediaTypeBytes(photoBytes: 10), iCloudDriveMedia: .zero)
        XCTAssertEqual(allCloudKit.cloudKitShareOfCloud, 1)

        XCTAssertNil(StorageUsageBreakdown(cloudKitMedia: nil, iCloudDriveMedia: .zero).cloudKitShareOfCloud)
        XCTAssertNil(StorageUsageBreakdown(cloudKitMedia: .zero, iCloudDriveMedia: .zero).cloudKitShareOfCloud,
                     "A share of nothing is not a number")
    }

    // MARK: - Typed and scalar views agree

    func testScalarAccessorsEqualTheTypedTotals() {
        let breakdown = StorageUsageBreakdown(
            localMedia: MediaTypeBytes(photoBytes: 100, videoBytes: 200, otherBytes: 3),
            cachedCloud: MediaTypeBytes(photoBytes: 10, videoBytes: 20, otherBytes: 1),
            thumbnailBytes: 5,
            indexBytes: 2
        )

        XCTAssertEqual(breakdown.localMediaBytes, 303)
        XCTAssertEqual(breakdown.cachedCloudBytes, 31)
        XCTAssertEqual(breakdown.totalDeviceBytes, 341)
        XCTAssertEqual(breakdown.reclaimableBytes, 38)
    }

    func testScalarInitializerMapsOntoTheTypedModel() {
        let breakdown = StorageUsageBreakdown(localMediaBytes: 7, cachedCloudBytes: 8, cloudBytes: 9)

        XCTAssertEqual(breakdown.localMedia, MediaTypeBytes(photoBytes: 7))
        XCTAssertEqual(breakdown.cachedCloud, MediaTypeBytes(otherBytes: 8))
        XCTAssertEqual(breakdown.cloudKitMedia?.totalBytes, 9)
        XCTAssertEqual(breakdown.iCloudDriveMedia, .zero)
        XCTAssertEqual(breakdown.cloudBytes, 9)
    }

    func testNegativeBucketsAreClampedToZero() {
        let breakdown = StorageUsageBreakdown(
            localMediaBytes: -1,
            cachedCloudBytes: -2,
            thumbnailBytes: -3,
            indexBytes: -4,
            cloudBytes: -5,
            legacyICloudDriveAlbumCount: -6
        )

        XCTAssertEqual(breakdown.totalDeviceBytes, 0)
        XCTAssertEqual(breakdown.cloudBytes, 0)
        XCTAssertEqual(breakdown.legacyICloudDriveAlbumCount, 0)
        XCTAssertTrue(breakdown.isEmpty)
    }
}
