//
//  AlbumGridItemCountTests.swift
//  EncameraCoreTests
//
//  The album tile's item count carries the number inside the localized phrase,
//  so it pluralizes per locale and groups digits with the locale's separator.
//

import XCTest
@testable import EncameraCore

final class AlbumGridItemCountTests: XCTestCase {

    func testSingularAndPlural() {
        XCTAssertEqual(L10n.AlbumGridItem.itemCount(0), "0 items")
        XCTAssertEqual(L10n.AlbumGridItem.itemCount(1), "1 item")
        XCTAssertEqual(L10n.AlbumGridItem.itemCount(2), "2 items")
    }

    func testCountUsesLocaleGroupingSeparator() {
        // L10n formats with Locale.current, which a test cannot swap, so format
        // the same localized phrase under explicit locales.
        let format = Bundle.module.localizedString(forKey: "AlbumGridItem.ItemCount", value: nil, table: "Localizable")

        XCTAssertEqual(String(format: format, locale: Locale(identifier: "en_US"), 2435), "2,435 items")
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "de_DE"), 2435), "2.435 items")
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "en_US"), 1), "1 item")
    }
}
