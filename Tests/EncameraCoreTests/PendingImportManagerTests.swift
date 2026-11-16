//
//  PendingImportManagerTests.swift
//  EncameraCoreTests
//
//  A share-sheet import is presented only if the caller that reacts to it sees
//  `hasPendingImports` as true. That caller often overlaps the
//  app-became-active check, so it must get that check's result, not the value
//  left over from before it. Media an import has claimed must not be offered
//  again while the import is still reading it, and media past its lifetime is
//  deleted before anything is counted.
//

import XCTest
@testable import EncameraCore

@MainActor
final class PendingImportManagerTests: XCTestCase {

    /// An in-memory staging folder. `pendingMediaURLs` can be held until the
    /// test releases it, to keep a check running.
    private final class FakeStaging: PendingImportStaging, @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _urls: [URL]
        private var _listCalls = 0
        private var _expiryCalls: [(cutoff: Date, excluded: Set<URL>)] = []
        private var _relaxed: [URL] = []
        var holdsListing = false

        init(fileNames: [String]) {
            _urls = fileNames.map { URL(fileURLWithPath: "/staging/\($0)") }
        }

        var urls: [URL] { lock.withLock { _urls } }
        var listCalls: Int { lock.withLock { _listCalls } }
        var expiryCalls: [(cutoff: Date, excluded: Set<URL>)] { lock.withLock { _expiryCalls } }
        var relaxed: [URL] { lock.withLock { _relaxed } }

        func release() {
            gate.signal()
        }

        func pendingMediaURLs() -> [URL] {
            lock.withLock { _listCalls += 1 }
            if holdsListing {
                gate.wait()
            }
            return urls
        }

        func enumerateMedia() async -> [CleartextMedia] {
            urls.map { CleartextMedia(source: $0) }
        }

        func delete(mediaList: [CleartextMedia]) async throws {
            let deleted = Set(mediaList.compactMap { media -> URL? in
                guard case .url(let url) = media.source else { return nil }
                return url
            })
            lock.withLock { _urls.removeAll { deleted.contains($0) } }
        }

        func deleteMedia(stagedBefore cutoff: Date, excluding excluded: Set<URL>) -> Int {
            lock.withLock { _expiryCalls.append((cutoff, excluded)) }
            return 0
        }

        func allowReadingWhileLocked(_ urls: [URL]) {
            lock.withLock { _relaxed.append(contentsOf: urls) }
        }
    }

    func testOverlappingCheckReturnsTheRunningChecksResult() async {
        let staging = FakeStaging(fileNames: ["a.jpeg"])
        staging.holdsListing = true
        let manager = PendingImportManager(staging: staging)
        XCTAssertFalse(manager.hasPendingImports)

        let first = Task { await manager.checkForPendingImports() }
        while staging.listCalls == 0 {
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

        staging.release()
        await first.value
        let hasPendingSeenBySecond = await second.value

        XCTAssertTrue(hasPendingSeenBySecond)
        XCTAssertEqual(manager.pendingCount, 1)
        XCTAssertEqual(staging.listCalls, 1, "The overlapping check should join the running one, not count again")
    }

    func testCheckAfterARunningCheckFinishesCountsAgain() async {
        let staging = FakeStaging(fileNames: ["a.jpeg", "b.mov"])
        let manager = PendingImportManager(staging: staging)

        await manager.checkForPendingImports()
        await manager.checkForPendingImports()

        XCTAssertEqual(staging.listCalls, 2)
        XCTAssertEqual(manager.pendingCount, 2)
    }

    func testCheckDeletesMediaOlderThanTheLifetime() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staging = FakeStaging(fileNames: ["a.jpeg"])
        let manager = PendingImportManager(staging: staging, now: { now })

        await manager.checkForPendingImports()

        XCTAssertEqual(staging.expiryCalls.count, 1)
        XCTAssertEqual(staging.expiryCalls.first?.cutoff, now.addingTimeInterval(-24 * 60 * 60))
    }

    func testClaimedMediaIsNotOfferedAgainWhileItsImportRuns() async {
        let staging = FakeStaging(fileNames: ["a.jpeg", "b.jpeg"])
        let manager = PendingImportManager(staging: staging)

        let claimed = await manager.claimPendingMedia()
        XCTAssertEqual(claimed.count, 2)
        XCTAssertEqual(Set(staging.relaxed), Set(staging.urls), "Claimed files should stay readable if the phone locks")

        await manager.checkForPendingImports()
        XCTAssertFalse(manager.hasPendingImports, "Files still on disk for a running import were offered again")
        XCTAssertEqual(staging.expiryCalls.last?.excluded, Set(staging.urls), "Expiry must skip files an import is reading")

        await manager.loadPendingMedia()
        XCTAssertTrue(manager.pendingMedia.isEmpty)
    }

    func testCancelLeavesClaimedMediaForItsImport() async throws {
        let staging = FakeStaging(fileNames: ["a.jpeg"])
        let manager = PendingImportManager(staging: staging)
        _ = await manager.claimPendingMedia()

        try await manager.cancelPendingImports()

        XCTAssertEqual(staging.urls.map(\.lastPathComponent), ["a.jpeg"])
    }

    func testReleasedClaimIsOfferedAgain() async {
        let staging = FakeStaging(fileNames: ["a.jpeg"])
        let manager = PendingImportManager(staging: staging)
        let claimed = await manager.claimPendingMedia()

        manager.releaseClaim(on: claimed)
        await manager.checkForPendingImports()

        XCTAssertTrue(manager.hasPendingImports)
    }
}
