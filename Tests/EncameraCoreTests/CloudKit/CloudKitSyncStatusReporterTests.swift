//
//  CloudKitSyncStatusReporterTests.swift
//  EncameraCoreTests
//
//  The reporter derives one user-facing activity from several independent
//  signals, so the interesting cases are the overlaps between them.
//

import XCTest
@testable import EncameraCore

@MainActor
final class CloudKitSyncStatusReporterTests: XCTestCase {

    /// A fresh instance, never `.shared`: this is observable state that would
    /// otherwise leak between tests.
    private func makeReporter() -> CloudKitSyncStatusReporter {
        CloudKitSyncStatusReporter()
    }

    func testStartsIdleWithNoSyncTime() {
        let reporter = makeReporter()
        XCTAssertEqual(reporter.activity, .idle)
        XCTAssertNil(reporter.lastSyncedAt)
    }

    func testReportsCheckingWhileReconciling() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        XCTAssertEqual(reporter.activity, .checking)
    }

    func testFinishedCheckGoesIdleAndStampsTheSyncTime() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: true)
        XCTAssertEqual(reporter.activity, .idle)
        XCTAssertNotNil(reporter.lastSyncedAt)
    }

    func testFailedCheckDoesNotStampSyncTime() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: false)
        XCTAssertEqual(reporter.activity, .idle)
        XCTAssertNil(reporter.lastSyncedAt, "a check that never reached iCloud must not claim a sync")
        XCTAssertTrue(reporter.lastCheckFailed)

        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: true)
        let stamped = reporter.lastSyncedAt
        XCTAssertNotNil(stamped)
        XCTAssertFalse(reporter.lastCheckFailed, "a successful check clears the failure")

        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: false)
        XCTAssertEqual(reporter.lastSyncedAt, stamped, "a later failure keeps the last real sync time")
        XCTAssertTrue(reporter.lastCheckFailed)
    }

    func testUploadingOutranksChecking() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportUploadProgress(completed: 1, total: 4)
        XCTAssertEqual(reporter.activity, .uploading(completed: 1, total: 4))
    }

    func testUploadFractionIsBoundedAndOnlyDeterminateForUploads() {
        XCTAssertEqual(CloudKitSyncActivity.uploading(completed: 1, total: 4).fractionCompleted, 0.25)
        XCTAssertEqual(CloudKitSyncActivity.uploading(completed: 9, total: 4).fractionCompleted, 1)
        XCTAssertNil(CloudKitSyncActivity.uploading(completed: 0, total: 0).fractionCompleted)
        XCTAssertNil(CloudKitSyncActivity.checking.fractionCompleted)
        XCTAssertNil(CloudKitSyncActivity.idle.fractionCompleted)
    }

    func testFinishedUploadsClearProgressAndSurfaceStalledItems() {
        let reporter = makeReporter()
        reporter.reportUploadProgress(completed: 2, total: 5)
        reporter.reportUploadsFinished(stalled: 3)
        XCTAssertEqual(reporter.activity, .stalled(count: 3))
    }

    func testDrainingBacklogIsNotAlsoReportedAsStalled() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 2)
        reporter.reportUploadProgress(completed: 0, total: 2)
        XCTAssertEqual(reporter.activity, .uploading(completed: 0, total: 2))
    }

    /// The whole point of staging: launch kicks an empty upload drain, which
    /// reports "nothing pending" and would otherwise wipe the staged state before
    /// a UI test could read it.
    func testStagedActivityOutlivesEveryProducerReport() {
        let reporter = makeReporter()
        reporter.stage(.stalled(count: 2))

        reporter.reportCheckStarted()
        reporter.reportUploadProgress(completed: 3, total: 3)
        reporter.reportUploadsFinished(stalled: 0)
        reporter.reportCheckFinished(succeeded: true)

        XCTAssertEqual(reporter.activity, .stalled(count: 2))
    }

    // MARK: - Completion

    /// The stalled count and the storage-full flag start at their defaults each
    /// launch, so a check that finishes before the first upload pass knows
    /// nothing yet about what is stuck.
    func testUpToDateWaitsForTheFirstUploadPass() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: true)
        XCTAssertNil(reporter.completion, "no upload pass has reported, so up to date is not known yet")

        reporter.reportUploadsFinished(stalled: 0)
        XCTAssertEqual(reporter.completion, .upToDate)
    }

    func testUploadPassAloneIsNotUpToDate() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 0)
        XCTAssertNil(reporter.completion, "nothing has checked iCloud yet")
    }

    func testFailedCheckIsUnreachableWithoutWaitingForAnUploadPass() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: false)
        XCTAssertEqual(reporter.completion, .unreachable)
    }

    // MARK: - Storage full

    func testUploadsBlockedByFullStorageReportStorageFull() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 3, storageFull: true)
        XCTAssertEqual(reporter.activity, .storageFull(stalled: 3))

        reporter.reportUploadsFinished(stalled: 1)
        XCTAssertEqual(reporter.activity, .stalled(count: 1),
                       "once no item gave up for storage, what is left is a plain stall")

        reporter.reportUploadsFinished(stalled: 0)
        XCTAssertEqual(reporter.activity, .idle)
    }

    func testAlbumSaveBlockedByFullStorageReportsStorageFull() {
        let reporter = makeReporter()
        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: true, storageFull: true)
        XCTAssertEqual(reporter.activity, .storageFull(stalled: 0))
        XCTAssertNotNil(reporter.lastSyncedAt, "the read side of the check still worked")

        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: false)
        XCTAssertEqual(reporter.activity, .storageFull(stalled: 0),
                       "a check that could not reach iCloud learned nothing about storage")

        reporter.reportCheckStarted()
        reporter.reportCheckFinished(succeeded: true)
        XCTAssertEqual(reporter.activity, .idle, "a check that saved everything clears it")
    }

    func testUploadingAndCheckingOutrankStorageFull() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 2, storageFull: true)
        reporter.reportCheckStarted()
        XCTAssertEqual(reporter.activity, .checking)
        reporter.reportUploadProgress(completed: 0, total: 2)
        XCTAssertEqual(reporter.activity, .uploading(completed: 0, total: 2))
    }

    func testStalledCountClearsOnceAPassAbandonsNothing() {
        let reporter = makeReporter()
        reporter.reportUploadsFinished(stalled: 2)
        reporter.reportUploadsFinished(stalled: 0)
        XCTAssertEqual(reporter.activity, .idle)
    }
}
