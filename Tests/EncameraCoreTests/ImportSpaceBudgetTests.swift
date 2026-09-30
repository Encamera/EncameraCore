//
//  ImportSpaceBudgetTests.swift
//  EncameraCoreTests
//

import XCTest
@testable import EncameraCore

final class ImportSpaceBudgetTests: XCTestCase {

    private let gib: Int64 = 1 << 30
    private let mib: Int64 = 1 << 20

    func testAllFitReturnsFitsAll() {
        let verdict = ImportSpaceBudget.evaluate(itemSizes: [10 * mib, 20 * mib, 30 * mib], freeBytes: 10 * gib)

        XCTAssertTrue(verdict.fitsAll)
        XCTAssertEqual(verdict.fitsCount, 3)
        XCTAssertEqual(verdict.totalCount, 3)
    }

    func testOverflowReturnsLongestFittingPrefix() {
        let free = Int64(2.6 * Double(gib))

        let verdict = ImportSpaceBudget.evaluate(itemSizes: [gib, gib, gib], freeBytes: free)

        // One item needs its stored bytes plus the same again for its temp
        // copy (~2.01 GiB) inside 2.1 GiB; a second pushes it past.
        XCTAssertFalse(verdict.fitsAll)
        XCTAssertEqual(verdict.fitsCount, 1)
    }

    func testRequiredBytesCountsOverheadThumbnailsAndLargestItem() {
        let verdict = ImportSpaceBudget.evaluate(itemSizes: [100 * mib, 300 * mib], freeBytes: 10 * gib)

        let expected = ImportSpaceBudget.storedBytes(forItemOfSize: 100 * mib)
            + ImportSpaceBudget.storedBytes(forItemOfSize: 300 * mib)
            + 300 * mib
        XCTAssertEqual(verdict.requiredBytes, expected)
    }

    func testReserveIsSubtracted() {
        let sizes: [Int64?] = [100 * mib]
        let required = ImportSpaceBudget.evaluate(itemSizes: sizes, freeBytes: 10 * gib).requiredBytes

        let verdict = ImportSpaceBudget.evaluate(itemSizes: sizes, freeBytes: required + ImportSpaceBudget.reserveBytes - 1)
        let justEnough = ImportSpaceBudget.evaluate(itemSizes: sizes, freeBytes: required + ImportSpaceBudget.reserveBytes)

        XCTAssertFalse(verdict.fitsAll)
        XCTAssertEqual(verdict.fitsCount, 0)
        XCTAssertTrue(justEnough.fitsAll)
    }

    func testUnknownSizesAreCountedButNotSummed() {
        let known = ImportSpaceBudget.evaluate(itemSizes: [50 * mib], freeBytes: 10 * gib)

        let verdict = ImportSpaceBudget.evaluate(itemSizes: [nil, 50 * mib, nil], freeBytes: 10 * gib)

        XCTAssertEqual(verdict.unknownCount, 2)
        XCTAssertEqual(verdict.requiredBytes, known.requiredBytes)
    }

    func testKnownBytesAloneCanOverflowWithUnknownsPresent() {
        let verdict = ImportSpaceBudget.evaluate(itemSizes: [nil, 2 * gib], freeBytes: gib)

        XCTAssertFalse(verdict.fitsAll)
        XCTAssertEqual(verdict.fitsCount, 1)
    }

    func testAllUnknownNeverBlocks() {
        let verdict = ImportSpaceBudget.evaluate(itemSizes: [nil, nil], freeBytes: 0)

        XCTAssertTrue(verdict.fitsAll)
        XCTAssertEqual(verdict.fitsCount, 2)
    }

    func testNilFreeBytesNeverBlocks() {
        let verdict = ImportSpaceBudget.evaluate(itemSizes: [100 * gib], freeBytes: nil)

        XCTAssertTrue(verdict.fitsAll)
    }
}
