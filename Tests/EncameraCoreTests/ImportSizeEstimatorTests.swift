//
//  ImportSizeEstimatorTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class ImportSizeEstimatorTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSizeEstimatorTests-\(UUID().uuidString).bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testURLSizeMatchesWrittenFile() throws {
        let bytes = 3 * 1024 * 1024
        try Data(count: bytes).write(to: tempURL)

        let sizes = ImportSizeEstimator().sizes(for: [tempURL])

        XCTAssertEqual(sizes.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sizes[0]), Int64(bytes))
    }

    func testMissingURLReturnsNil() {
        let sizes = ImportSizeEstimator().sizes(for: [tempURL])

        XCTAssertEqual(sizes, [nil])
    }

    /// `PHPickerResult` has no public initializer, so this drives the path a
    /// picker result takes once its identifier is read.
    func testPickerResultWithoutAssetIdentifierReturnsNil() {
        XCTAssertNil(ImportSizeEstimator().size(forAssetIdentifier: nil))
    }

    func testPickerResultWithUnresolvableAssetIdentifierReturnsNil() {
        XCTAssertNil(ImportSizeEstimator().size(forAssetIdentifier: "not-a-real-asset/L0/001"))
    }
}
