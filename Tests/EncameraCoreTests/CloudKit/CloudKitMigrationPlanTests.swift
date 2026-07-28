//
//  CloudKitMigrationPlanTests.swift
//  EncameraCoreTests
//
//  The migration plan is the durable checkpoint that makes a local -> CloudKit
//  album migration resumable across a crash/kill. These tests pin its byte-weighted
//  progress math and the encrypted, atomic, crash-safe persistence envelope.
//

import XCTest
@testable import EncameraCore

final class CloudKitMigrationPlanTests: XCTestCase {

    private func makeTempPlanURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitMigrationPlanTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plan.encplan")
    }

    private func randomKey() -> [UInt8] {
        (0..<32).map { _ in UInt8.random(in: 0...255) }
    }

    private func makeItem(id: String = UUID().uuidString,
                          type: MediaType = .photo,
                          size: Int64 = 1_000,
                          state: MigrationItemState = .pending) -> MigrationItem {
        MigrationItem(
            mediaID: id,
            recordName: "\(id)#\(type.rawValue)",
            mediaType: type,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            sizeBytes: size,
            state: state
        )
    }

    private func makePlan(items: [MigrationItem]) -> MigrationPlan {
        MigrationPlan(
            albumName: "Vacation",
            sourceStorage: .local,
            items: items,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
    }

    // MARK: - Progress math

    func testByteWeightedFractionUsesVerifiedAndDeletedOnly() {
        let plan = makePlan(items: [
            makeItem(size: 100, state: .verified),
            makeItem(size: 300, state: .sourceDeleted),
            makeItem(size: 600, state: .uploading),    // in flight: not yet counted
        ])
        XCTAssertEqual(plan.totalBytes, 1000)
        XCTAssertEqual(plan.migratedBytes, 400)
        XCTAssertEqual(plan.fractionComplete, 0.4, accuracy: 0.0001)
        XCTAssertEqual(plan.verifiedCount, 2)
    }

    func testEmptyPlanIsFullyComplete() {
        let plan = makePlan(items: [])
        XCTAssertEqual(plan.fractionComplete, 1.0)
        XCTAssertFalse(plan.isComplete, "an empty plan has no work, so it is not 'complete' in the has-items sense")
        XCTAssertFalse(plan.hasRemainingWork)
    }

    func testIsCompleteOnlyWhenEveryItemSourceDeleted() {
        XCTAssertFalse(makePlan(items: [makeItem(state: .verified)]).isComplete)
        XCTAssertTrue(makePlan(items: [makeItem(state: .sourceDeleted),
                                       makeItem(state: .sourceDeleted)]).isComplete)
    }

    func testHasRemainingWorkAndFailedCount() {
        let plan = makePlan(items: [
            makeItem(state: .sourceDeleted),
            makeItem(state: .failed),
        ])
        XCTAssertTrue(plan.hasRemainingWork)
        XCTAssertEqual(plan.failedCount, 1)
    }

    func testSkippedItemIsTerminalAndAllowsCompletion() {
        XCTAssertTrue(MigrationItemState.skipped.isDone, "a skipped item needs no further work")
        let plan = makePlan(items: [
            makeItem(state: .sourceDeleted),
            makeItem(state: .skipped),   // source file was missing — nothing to migrate
        ])
        XCTAssertTrue(plan.isComplete, "a migration completes even when an unmigratable item is skipped")
        XCTAssertFalse(plan.hasRemainingWork, "a skipped item is not retried forever")
        XCTAssertEqual(plan.failedCount, 0, "skipped is terminal, not a failure")
    }

    // MARK: - Persistence

    func testSaveThenLoadRoundTrips() async throws {
        let key = randomKey()
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let plan = makePlan(items: [
            makeItem(id: "a", type: .photo, size: 10, state: .verified),
            makeItem(id: "b", type: .video, size: 20, state: .uploading),
        ])
        try await MigrationPlanStore(keyBytes: key, planURL: url).save(plan)

        let loaded = await MigrationPlanStore(keyBytes: key, planURL: url).load()
        XCTAssertEqual(loaded?.albumName, "Vacation")
        XCTAssertEqual(loaded?.sourceStorage, .local)
        XCTAssertEqual(loaded?.items.count, 2)
        XCTAssertEqual(loaded?.items.first?.mediaID, "a")
        XCTAssertEqual(loaded?.items.first?.mediaType, .photo)
        XCTAssertEqual(loaded?.items.first?.state, .verified)
        XCTAssertEqual(loaded?.items.last?.mediaType, .video)
        XCTAssertEqual(loaded?.totalBytes, 30)
    }

    func testLoadReturnsNilWhenAbsent() async throws {
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = await MigrationPlanStore(keyBytes: randomKey(), planURL: url).load()
        XCTAssertNil(loaded)
    }

    func testLoadReturnsNilOnCorruptOrTruncatedFile() async throws {
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Garbage bytes (a crash mid-write could leave a partial file).
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        let loaded = await MigrationPlanStore(keyBytes: randomKey(), planURL: url).load()
        XCTAssertNil(loaded, "a corrupt/truncated checkpoint must read as absent, not crash")
    }

    func testLoadReturnsNilWithWrongKey() async throws {
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await MigrationPlanStore(keyBytes: randomKey(), planURL: url).save(makePlan(items: [makeItem()]))
        let loaded = await MigrationPlanStore(keyBytes: randomKey(), planURL: url).load()
        XCTAssertNil(loaded, "the plan is encrypted with the album key; a different key cannot read it")
    }

    func testDeleteRemovesPlanFile() async throws {
        let key = randomKey()
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = MigrationPlanStore(keyBytes: key, planURL: url)
        try await store.save(makePlan(items: [makeItem()]))
        var exists = await store.exists()
        XCTAssertTrue(exists)

        await store.delete()
        exists = await store.exists()
        XCTAssertFalse(exists)
    }

    func testResaveOverwritesAtomically() async throws {
        let key = randomKey()
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = MigrationPlanStore(keyBytes: key, planURL: url)
        try await store.save(makePlan(items: [makeItem(id: "a", state: .pending)]))
        try await store.save(makePlan(items: [makeItem(id: "a", state: .sourceDeleted)]))

        let loaded = await store.load()
        XCTAssertEqual(loaded?.items.first?.state, .sourceDeleted, "the latest save wins")
    }
}
