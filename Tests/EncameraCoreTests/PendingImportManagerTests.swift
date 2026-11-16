//
//  PendingImportManagerTests.swift
//  EncameraCoreTests
//
//  A share-sheet import is presented only if the caller that reacts to the
//  `encamera://pendingImport` link sees `hasPendingImports` as true. That link
//  arrives while the app-became-active check is often still counting files, so
//  a caller that overlaps a running check must get that check's result, not the
//  value left over from before it.
//

import XCTest
@testable import EncameraCore

@MainActor
final class PendingImportManagerTests: XCTestCase {

    /// Counts calls and blocks each one until the test releases it.
    private final class GatedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _calls = 0
        let count: Int

        init(count: Int) {
            self.count = count
        }

        var calls: Int {
            lock.withLock { _calls }
        }

        func pendingMediaCount() -> Int {
            lock.withLock { _calls += 1 }
            gate.wait()
            return count
        }

        func release() {
            gate.signal()
        }
    }

    func testOverlappingCheckReturnsTheRunningChecksResult() async {
        let counter = GatedCounter(count: 1)
        let manager = PendingImportManager(pendingMediaCount: counter.pendingMediaCount)
        XCTAssertFalse(manager.hasPendingImports)

        let first = Task { await manager.checkForPendingImports() }
        while counter.calls == 0 {
            await Task.yield()
        }

        var secondReturned = false
        let second = Task {
            await manager.checkForPendingImports()
            secondReturned = true
            return manager.hasPendingImports
        }
        for _ in 0..<50 {
            await Task.yield()
        }
        XCTAssertFalse(secondReturned, "An overlapping check returned before the running check finished")

        counter.release()
        await first.value
        let hasPendingSeenBySecond = await second.value

        XCTAssertTrue(hasPendingSeenBySecond)
        XCTAssertEqual(manager.pendingCount, 1)
        XCTAssertEqual(counter.calls, 1, "The overlapping check should join the running one, not count again")
    }

    func testCheckAfterARunningCheckFinishesCountsAgain() async {
        let counter = GatedCounter(count: 2)
        let manager = PendingImportManager(pendingMediaCount: counter.pendingMediaCount)

        counter.release()
        await manager.checkForPendingImports()
        counter.release()
        await manager.checkForPendingImports()

        XCTAssertEqual(counter.calls, 2)
        XCTAssertEqual(manager.pendingCount, 2)
    }
}
