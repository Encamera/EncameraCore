//
//  RequestedAlbumSeedTests.swift
//  EncameraCoreTests
//
//  The albums a launch requests on a device that never stored the requested
//  albums: those with a migration plan on this device, sorted by name, and only
//  while no list is stored. Then the scheduler continues them one at a time.
//

import XCTest
@testable import EncameraCore

@MainActor
final class RequestedAlbumSeedTests: XCTestCase {

    typealias SeedAlbum = (albumID: String, displayName: String?)

    private func seededIDs(_ albums: [SeedAlbum], plans: Set<String>) -> [String] {
        ICloudDriveBlobMigration.albumIDsToRequestForExistingPlans(albums: albums, hasPlan: { plans.contains($0) })
    }

    /// A store in a fresh temporary directory, with no file yet.
    private func makeStore() -> RequestedUpgradesStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("requested-seed-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return RequestedUpgradesStore(directory: directory)
    }

    private func seed(_ harness: SchedulerHarness, albums: [SeedAlbum], plans: Set<String>) {
        ICloudDriveBlobMigration.requestAlbumsWithPlansIfNoListIsStored(
            scheduler: harness.scheduler, albums: { albums }, hasPlan: { plans.contains($0) })
    }

    // MARK: - Which albums, in what order

    func testSeedsOnlyAlbumsWithAPlan() {
        let albums: [SeedAlbum] = [("a", "Alpha"), ("b", "Beta"), ("c", "Gamma")]

        XCTAssertEqual(seededIDs(albums, plans: ["a", "c"]), ["a", "c"])
        XCTAssertEqual(seededIDs(albums, plans: []), [])
    }

    func testSkipsAnAlbumAnotherDeviceStarted() {
        // Linked to an iCloud Drive folder by the album-folder walk here, but its
        // plan is on the device that started it.
        let albums: [SeedAlbum] = [("mine", "Holiday"), ("theirs", "Another device's")]

        XCTAssertEqual(seededIDs(albums, plans: ["mine"]), ["mine"])
    }

    func testSeedsInAlphabeticalOrder() {
        let albums: [SeedAlbum] = [
            ("ten", "a 10"), ("two", "a 2"), ("zebra", "Zebra"), ("eclair", "Éclair"),
            ("apple", "apple"), ("banana", "Banana"), ("edam", "edam")
        ]
        let plans = Set(albums.map(\.albumID))

        XCTAssertEqual(seededIDs(albums, plans: plans),
                       ["two", "ten", "apple", "banana", "eclair", "edam", "zebra"])
    }

    func testAlbumsWithoutAReadableNameGoLast() {
        let albums: [SeedAlbum] = [("z-locked", nil), ("b", "Beta"), ("a-locked", nil), ("c", "alpha")]
        let plans = Set(albums.map(\.albumID))

        XCTAssertEqual(seededIDs(albums, plans: plans), ["c", "b", "a-locked", "z-locked"])
    }

    // MARK: - Only while no list is stored

    func testSeedsWhenNoListIsStored() {
        let store = makeStore()
        let harness = SchedulerHarness(requestedUpgradesStore: store)

        seed(harness, albums: [("b", "Beta"), ("a", "Alpha"), ("x", "Other")], plans: ["a", "b"])

        XCTAssertEqual(harness.scheduler.state.order, ["a", "b"])
        XCTAssertEqual(store.loadAlbumIDs(), ["a", "b"], "the seeded order is stored, so it happens once")
        XCTAssertFalse(harness.scheduler.hasNoStoredRequestedList)
    }

    func testSeedsNothingWhenTheStoredListExists() throws {
        let store = makeStore()
        try store.saveAlbumIDs(["b"])
        let harness = SchedulerHarness(requestedUpgradesStore: store)

        seed(harness, albums: [("a", "Alpha"), ("b", "Beta")], plans: ["a", "b"])

        XCTAssertEqual(harness.scheduler.state.order, ["b"])
        XCTAssertEqual(store.loadAlbumIDs(), ["b"])
    }

    func testSeedsNothingAfterAnEmptyListWasSaved() throws {
        let store = makeStore()
        try store.saveAlbumIDs([])
        let harness = SchedulerHarness(requestedUpgradesStore: store)

        seed(harness, albums: [("a", "Alpha")], plans: ["a"])

        XCTAssertEqual(harness.scheduler.state.order, [], "an album the user paused or the scheduler dropped stays out")
        XCTAssertEqual(store.loadAlbumIDs(), [])
    }

    func testSeedsNothingWhileLocked() {
        let store = makeStore()
        let harness = SchedulerHarness(requestedUpgradesStore: store)
        harness.isUnlocked = false

        seed(harness, albums: [("a", "Alpha")], plans: ["a"])

        XCTAssertEqual(harness.scheduler.state.order, [])
        XCTAssertFalse(store.fileExists, "the next unlocked launch still seeds")
    }

    // MARK: - Continuing the seeded albums

    func testSeededAlbumsContinueOneAtATimeAtLaunch() async throws {
        let store = makeStore()
        let harness = SchedulerHarness(requestedUpgradesStore: store)
        harness.finishAlbumsWhosePassEnds = true
        harness.runner.holdPass(ofAlbumID: "a")

        seed(harness, albums: [("c", "Gamma"), ("a", "Alpha"), ("b", "Beta"), ("x", "Not started here")],
             plans: ["a", "b", "c"])
        XCTAssertEqual(harness.albumStepsRun, [], "requesting starts nothing by itself")
        XCTAssertEqual(harness.runner.executedAlbumIDs, [])

        harness.scheduler.continueRequestedUpgrades()
        try await harness.waitUntil("the first seeded album's pass runs") { harness.runner.executedAlbumIDs == ["a"] }

        XCTAssertEqual(harness.albumStepsRun, ["a"], "only the first album gets its album step while its pass runs")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("every seeded album ends") { harness.isIdle && harness.scheduler.state.order.isEmpty }

        XCTAssertEqual(harness.albumStepsRun, ["a", "b", "c"])
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "b", "c"])
        XCTAssertEqual(harness.runner.mostPassesRunningAtOnce, 1)
        XCTAssertEqual(store.loadAlbumIDs(), [], "the emptied order is stored, so the next launch seeds nothing")
        XCTAssertTrue(store.fileExists)
    }
}
