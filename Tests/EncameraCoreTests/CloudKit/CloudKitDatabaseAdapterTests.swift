//
//  CloudKitDatabaseAdapterTests.swift
//  EncameraCoreTests
//
//  The adapter's error-surfacing contract: per-record failures of an
//  overall-successful CKModifyRecordsOperation must reach callers in the same
//  `.partialFailure` shape a failed operation produces — carrying EVERY failed
//  record — so `mapCKError`/`unwrapPartial` handle them deterministically
//  (Dictionary.first would leak an arbitrary raw error instead).
//

import XCTest
import CloudKit
@testable import EncameraCore

@MainActor
final class CloudKitDatabaseAdapterTests: XCTestCase {

    func testPerRecordSaveFailuresSurfaceAsPartialCarryingEveryRecord() {
        let failures: [CKRecord.ID: Error] = [
            CKRecord.ID(recordName: "r-quota"): CKErrorFactory.error(.quotaExceeded),
            CKRecord.ID(recordName: "r-conflict"): CKErrorFactory.error(.serverRecordChanged),
        ]

        let mapped = mapCKError(CKDatabaseAdapter.perRecordSaveFailureError(failures))

        guard case .partial(let failed) = mapped else {
            return XCTFail("expected .partial so the caller can unwrap deterministically, got \(mapped)")
        }
        XCTAssertEqual(Set(failed.keys), ["r-quota", "r-conflict"],
                       "every per-record failure is carried — never an arbitrary Dictionary.first pick")
    }

    func testSinglePerRecordSaveFailureMatchesTheDocumentedPartialShape() {
        // CloudKitMigrationManager is written on the documented assumption that
        // the real adapter reports per-record failures wrapped in
        // `.partialFailure` (see its `unwrapPartial` call sites).
        let failures: [CKRecord.ID: Error] = [
            CKRecord.ID(recordName: "r1"): CKErrorFactory.error(.serverRecordChanged),
        ]

        let mapped = mapCKError(CKDatabaseAdapter.perRecordSaveFailureError(failures))

        guard case .partial = mapped else {
            return XCTFail("expected the wrapped .partial shape the migration manager unwraps, got \(mapped)")
        }
        guard case .conflict = CloudKitMigrationManager.unwrapPartial(mapped) else {
            return XCTFail("a single-record partial must unwrap to its underlying error")
        }
    }
}
