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

    /// Swift task cancellation has to reach the CKOperation. Without this, a
    /// cancelled blob download kept transferring in the background — the user's
    /// Cancel stopped nothing, it only stopped them watching.
    func testCancellingTheAwaitingTaskCancelsTheCloudKitOperation() async throws {
        let operation = CKFetchRecordsOperation(recordIDs: [CKRecord.ID(recordName: "m1")])
        let held = ContinuationBox()
        let started = expectation(description: "the operation was dispatched")

        let task = Task {
            try await CKDatabaseAdapter.runCancellable(operation) { continuation in
                held.store(continuation)
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 5)

        task.cancel()
        // The cancellation handler runs off this task; give it a beat to land.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(operation.isCancelled,
                      "Cancelling the awaiting task must cancel the CKOperation, not just abandon it")

        // CloudKit would now complete the cancelled operation with an error; stand in
        // for it so the task unwinds instead of leaking a continuation.
        held.resume(throwing: CKErrorFactory.error(.operationCancelled))
        _ = try? await task.value
    }
}

/// Holds a continuation the test resumes by hand, standing in for CloudKit's
/// completion block.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CKRecord.ID: CKRecord], Error>?

    func store(_ continuation: CheckedContinuation<[CKRecord.ID: CKRecord], Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
