//
//  StorageTypeTests.swift
//  EncameraCoreTests
//
//  ENC-88. `.icloud` (deprecated iCloud Drive) and `.cloudKit` used to render
//  identically — same `title`, same `iconName`, same `description`, same
//  `locationName`, same artwork. That was latent only because the two were never
//  offered at the same time; during migration they are, and a user picking a
//  storage destination (or a UI test tapping one) has no way to tell them apart.
//
//  These tests assert over `StorageType.allCases` rather than a hardcoded list so
//  a newly added case is covered automatically and cannot reintroduce a collision.
//

import XCTest
@testable import EncameraCore

final class StorageTypeTests: XCTestCase {

    func testStorageTypeLabelsAreUnique() {
        let labelSets: [(name: String, value: (StorageType) -> String)] = [
            ("title", { $0.title }),
            ("iconName", { $0.iconName }),
            ("description", { $0.description }),
            ("locationName", { $0.locationName })
        ]

        for label in labelSets {
            var seen: [String: StorageType] = [:]
            for type in StorageType.allCases {
                let value = label.value(type)
                XCTAssertFalse(
                    value.isEmpty,
                    "\(label.name) for .\(type.rawValue) must not be empty"
                )
                if let clash = seen[value] {
                    XCTFail(
                        "\(label.name) collision: .\(type.rawValue) and .\(clash.rawValue) both render \"\(value)\""
                    )
                }
                seen[value] = type
            }
        }
    }

    /// The specific pairing the deprecation depends on: legacy iCloud Drive must be
    /// visibly marked as legacy, and CloudKit keeps the plain "iCloud" wording.
    func testICloudDriveIsLabelledDistinctlyFromCloudKit() {
        XCTAssertNotEqual(StorageType.icloud.title, StorageType.cloudKit.title)
        XCTAssertEqual(StorageType.cloudKit.title, "iCloud")
        XCTAssertTrue(
            StorageType.icloud.title.localizedCaseInsensitiveContains("drive"),
            "the legacy case should name iCloud Drive explicitly, got \(StorageType.icloud.title)"
        )
    }

    /// Deprecation applies to *new* data only. Existing iCloud Drive albums must stay
    /// readable, so the two questions are answered by two different functions.
    func testICloudDriveIsNeverOfferedButStaysReadable() {
        guard case .unavailable = DataStorageAvailabilityUtil.isStorageTypeOfferedForNewAlbums(type: .icloud) else {
            return XCTFail("iCloud Drive must never be offered as a destination for new albums")
        }

        // Readability tracks the ubiquity container only — no deprecation gate. The
        // simulator has no container, so assert on the *reason* rather than on
        // availability, which would make this environment-dependent.
        let readable = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud)
        if case .unavailable(let reason) = readable {
            XCTAssertEqual(
                reason,
                L10n.noICloudAccountFoundOnThisDevice,
                "the only reason existing iCloud Drive data may be unreadable is a missing container"
            )
        }
    }

    func testLocalStorageIsAlwaysAvailable() {
        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .local), .available)
        XCTAssertEqual(DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .local), .available)
    }
}
