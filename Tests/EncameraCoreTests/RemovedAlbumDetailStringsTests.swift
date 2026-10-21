//
//  RemovedAlbumDetailStringsTests.swift
//  EncameraCoreTests
//
//  The album screen's photo-access and no-license alerts were removed, and
//  their copy with them. These keys must stay gone from every language, while
//  the similarly named keys that are still read must keep resolving.
//

import XCTest
@testable import EncameraCore

final class RemovedAlbumDetailStringsTests: XCTestCase {

    private static let sentinel = "__missing__"

    private static let removedKeys = [
        "AlbumDetailView.PhotoAccessAlertTitle",
        "AlbumDetailView.PhotoAccessAlertMessage",
        "AlbumDetailView.PhotoAccessAlertPrimaryButton",
        "AlbumDetailView.PhotoAccessAlertSecondaryButton",
        "AlbumDetailView.PhotoAccessRequired",
        "AlbumDetailView.PhotoAccessSettings",
        "AlbumDetailView.OpenSettings",
        "AlbumDetailView.NoLicenseDeletionWarningTitle",
        "AlbumDetailView.NoLicenseDeletionWarningMessage",
        "AlbumDetailView.NoLicenseDeletionWarningPrimaryButton"
    ]

    private static let lookalikeKeys = [
        "OpenSettings",
        "CustomPhotoPicker.PhotoAccessRequired",
        "AlbumDetailView.SortFilter.Photos",
        "AlbumDetailView.SortFilter.Videos",
        "AlbumDetailView.SortFilter.ResetFilters"
    ]

    /// One bundle per `.lproj` in EncameraCore's resource bundle, so each
    /// language's table is checked on its own rather than through fallback.
    private func localizationBundles() throws -> [(String, Bundle)] {
        let lprojURLs = try XCTUnwrap(
            Bundle.module.urls(forResourcesWithExtension: "lproj", subdirectory: nil),
            "EncameraCore's resource bundle has no .lproj directories"
        )
        return try lprojURLs
            .filter { $0.deletingPathExtension().lastPathComponent != "Base" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                (url.lastPathComponent, try XCTUnwrap(Bundle(url: url), "Cannot open \(url.lastPathComponent)"))
            }
    }

    private func lookup(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: Self.sentinel, table: "Localizable")
    }

    func testRemovedKeysAreAbsentInEveryLocalization() throws {
        let bundles = try localizationBundles()
        XCTAssertEqual(bundles.count, 13, "Expected 13 localizations, found \(bundles.map(\.0))")

        for (name, bundle) in bundles {
            // Guard against a vacuous pass: a table that failed to load would
            // return the sentinel for every key, removed or not.
            XCTAssertNotEqual(lookup("OpenSettings", in: bundle), Self.sentinel,
                              "\(name) Localizable table did not load")

            for key in Self.removedKeys {
                XCTAssertEqual(lookup(key, in: bundle), Self.sentinel, "\(key) is still present in \(name)")
            }
        }
    }

    func testLookalikeKeysSurvive() throws {
        let english = try XCTUnwrap(
            localizationBundles().first { $0.0 == "en.lproj" }?.1,
            "EncameraCore's resource bundle has no en.lproj"
        )
        for key in Self.lookalikeKeys {
            XCTAssertNotEqual(lookup(key, in: english), Self.sentinel, "\(key) no longer resolves in en")
        }
    }
}
