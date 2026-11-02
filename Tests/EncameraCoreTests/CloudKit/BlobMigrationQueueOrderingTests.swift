//
//  BlobMigrationQueueOrderingTests.swift
//  EncameraCoreTests
//
//  The iCloud Drive migration queue: each plan item's stored kind and priority
//  request, the one ordering function over them, and `prioritize`, the one
//  operation that records a user request.
//

import XCTest
@testable import EncameraCore

final class BlobMigrationQueueOrderingTests: XCTestCase {

    private static let large = Int64(SeekableEncryptedFormat.threshold)
    private static let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func date(_ offset: TimeInterval) -> Date { Self.base.addingTimeInterval(offset) }

    private func item(_ id: String,
                      type: MediaType = .photo,
                      size: Int64 = 1_000,
                      created: TimeInterval = 0,
                      state: MigrationItemState = .pending,
                      request: MigrationPriorityReason? = nil,
                      requestedAt: TimeInterval = 0) -> MigrationItem {
        MigrationItem(mediaID: id,
                      recordName: MediaRecordName.componentRecordName(mediaID: id, type: type),
                      mediaType: type,
                      createdAt: date(created),
                      sizeBytes: size,
                      state: state,
                      priorityRequest: request.map { MigrationPriorityRequest(reason: $0, requestedAt: date(requestedAt)) })
    }

    private func encrypting(_ id: String, created: TimeInterval = 0,
                            request: MigrationPriorityReason? = nil, requestedAt: TimeInterval = 0) -> MigrationItem {
        item(id, type: .video, size: Self.large, created: created, request: request, requestedAt: requestedAt)
    }

    private func ids(_ items: [MigrationItem]) -> [String] { items.map(\.mediaID) }

    private func order(_ items: [MigrationItem], _ state: BlobMigrationDeviceState = .unlocked) -> [MigrationItem] {
        BlobMigrationOrder.next(items: items, deviceState: state)
    }

    // MARK: - Tiers

    func testUserRequestedItemsComeFirstInRequestOrder() {
        let items = [
            item("plain", created: 900),
            item("second", created: 1, request: .userAction, requestedAt: 20),
            item("viewed", created: 2, request: .viewed, requestedAt: 50),
            item("first", created: 0, request: .userAction, requestedAt: 10),
            item("third", created: 500, request: .userAction, requestedAt: 30),
        ]

        let ordered = ids(order(items))

        XCTAssertEqual(Array(ordered.prefix(3)), ["first", "second", "third"])
    }

    func testViewedItemsComeAfterUserRequestedMostRecentlyViewedFirst() {
        let items = [
            item("viewedEarly", request: .viewed, requestedAt: 10),
            item("requested", request: .userAction, requestedAt: 5),
            item("viewedLate", request: .viewed, requestedAt: 30),
            item("viewedMiddle", request: .viewed, requestedAt: 20),
        ]

        XCTAssertEqual(ids(order(items)), ["requested", "viewedLate", "viewedMiddle", "viewedEarly"])
    }

    func testViewedItemsComeBeforeEncryptingAndCiphertextOnly() {
        let items = [
            encrypting("bigVideo", created: 900),
            item("newPhoto", created: 800),
            item("viewed", created: 0, request: .viewed, requestedAt: 1),
        ]

        XCTAssertEqual(ids(order(items)), ["viewed", "bigVideo", "newPhoto"])
    }

    func testLockedNeverReturnsEncryptingItems() {
        let items = [
            encrypting("requestedVideo", request: .userAction, requestedAt: 1),
            encrypting("viewedVideo", request: .viewed, requestedAt: 2),
            encrypting("plainVideo"),
            item("photo"),
        ]

        let locked = order(items, .locked)

        XCTAssertFalse(locked.contains { $0.kind == .encrypting })
        XCTAssertEqual(ids(locked), ["photo"])
    }

    func testLockedReturnsCiphertextOnlyItems() {
        let items = [
            item("requested", request: .userAction, requestedAt: 1),
            item("viewed", request: .viewed, requestedAt: 2),
            item("smallVideo", type: .video, size: Self.large - 1, created: 5),
            item("photo", created: 1),
            encrypting("bigVideo", created: 10),
        ]

        XCTAssertEqual(ids(order(items, .locked)), ["requested", "viewed", "smallVideo", "photo"])
    }

    func testUnlockedPutsEncryptingBeforeCiphertextOnly() {
        let items = [
            item("newestPhoto", created: 100),
            encrypting("oldVideo", created: 1),
            encrypting("newerVideo", created: 50),
            item("oldPhoto", created: 0),
        ]

        XCTAssertEqual(ids(order(items)), ["newerVideo", "oldVideo", "newestPhoto", "oldPhoto"])
    }

    func testCiphertextOnlyIsMostRecentFirst() {
        let items = [
            item("middle", created: 50),
            item("oldest", created: 0),
            item("newest", created: 100),
            item("done", created: 200, state: .sourceDeleted),
            item("skipped", created: 300, state: .skipped),
        ]

        XCTAssertEqual(ids(order(items, .locked)), ["newest", "middle", "oldest"])
        XCTAssertEqual(ids(order(items, .unlocked)), ["newest", "middle", "oldest"])
    }

    func testLivePhotoHalvesStayAdjacentInEveryTier() {
        func live(_ id: String, created: TimeInterval, request: MigrationPriorityReason? = nil,
                  requestedAt: TimeInterval = 0) -> [MigrationItem] {
            [item(id, type: .photo, created: created, request: request, requestedAt: requestedAt),
             item(id, type: .video, size: 4_000, created: created, request: request, requestedAt: requestedAt)]
        }
        let items = [encrypting("bigVideoA", created: 70)]
            + live("liveCiphertext", created: 60)
            + [item("photoB", created: 65)]
            + live("liveViewed", created: 0, request: .viewed, requestedAt: 40)
            + [item("viewedC", request: .viewed, requestedAt: 45), encrypting("bigVideoD", created: 50)]
            + live("liveRequested", created: 0, request: .userAction, requestedAt: 5)
            + [item("requestedE", request: .userAction, requestedAt: 6), item("photoF", created: 55)]

        for state in [BlobMigrationDeviceState.locked, .unlocked] {
            let ordered = order(items, state)
            for id in ["liveCiphertext", "liveViewed", "liveRequested"] {
                let positions = ordered.indices.filter { ordered[$0].mediaID == id }
                XCTAssertEqual(positions.count, 2, "\(id) has both halves when \(state)")
                XCTAssertEqual(positions[1] - positions[0], 1, "\(id) halves are adjacent when \(state)")
            }
        }
        XCTAssertEqual(ids(order(items)), ["liveRequested", "liveRequested", "requestedE",
                                           "viewedC", "liveViewed", "liveViewed",
                                           "bigVideoA", "bigVideoD",
                                           "photoB", "liveCiphertext", "liveCiphertext", "photoF"])
    }

    func testLivePhotoWithAnEncryptingHalfRunsTogetherInTheBestTier() {
        let items = [item("photoNewer", created: 100),
                     item("live", type: .photo, created: 0),
                     item("live", type: .video, size: Self.large, created: 0)]

        XCTAssertEqual(ids(order(items)), ["live", "live", "photoNewer"],
                       "unlocked, the encrypting half lifts its photo into the encrypting tier")
        XCTAssertEqual(order(items, .locked).map(\.recordName),
                       [MediaRecordName.componentRecordName(mediaID: "photoNewer", type: .photo),
                        MediaRecordName.componentRecordName(mediaID: "live", type: .photo)],
                       "locked, only the ciphertext-only half is eligible")
    }

    func testSeedBreaksTiesBeforeMediaID() {
        let items = [item("a", created: 10), item("b", created: 10), item("c", created: 10)]
        let seeds: [String: UInt64] = ["a": 3, "b": 1, "c": 2]

        XCTAssertEqual(ids(order(items)), ["a", "b", "c"])
        XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked) { seeds[$0] ?? 0 }),
                       ["b", "c", "a"])
    }

    // MARK: - Deferred items

    private func deferred(_ item: MigrationItem, _ reason: MigrationDeferralReason = .unreadable) -> MigrationItem {
        var item = item
        item.deferralReason = reason
        return item
    }

    func testDeferredTierRunsLast() {
        let items = [
            deferred(item("deferred-old", created: 0), .missingKey),
            deferred(item("deferred-requested", created: 1, request: .userAction, requestedAt: 5)),
            deferred(encrypting("deferred-encrypting", created: 2), .neverDownloads),
            item("plain", created: 3),
            encrypting("encrypting", created: 4),
            deferred(item("deferred-new", created: 900), .recordInAnotherAlbum),
            item("viewed", created: 5, request: .viewed, requestedAt: 10),
        ]
        XCTAssertEqual(ids(order(items, .unlocked)),
                       ["viewed", "encrypting", "plain",
                        "deferred-new", "deferred-encrypting", "deferred-requested", "deferred-old"],
                       "deferred items run last, in seed order, and a request does not lift them")

        // Locked, no deferred item is encrypted either.
        XCTAssertEqual(ids(order(items, .locked)),
                       ["viewed", "plain", "deferred-new", "deferred-requested", "deferred-old"])

        // The seed orders the tier as it does the others.
        let seeds = ["deferred-old": 1, "deferred-new": 3, "deferred-requested": 2, "deferred-encrypting": 4] as [String: UInt64]
        XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked) { seeds[$0] ?? 0 }).suffix(4),
                       ["deferred-old", "deferred-requested", "deferred-new", "deferred-encrypting"])
    }

    // MARK: - Device seed

    private static let deviceA = "6F1D2A3B-0000-4000-8000-000000000001"
    private static let deviceB = "6F1D2A3B-0000-4000-8000-000000000002"

    /// Twenty items with distinct dates in one tier.
    private func distinctlyDated(_ make: (String, TimeInterval) -> MigrationItem) -> [MigrationItem] {
        (0..<20).map { make("p\($0)", TimeInterval($0) * 100) }
    }

    func testSeedIsSHA256OfDeviceIDAndMediaID() {
        // python3 -c 'import hashlib; print(int.from_bytes(hashlib.sha256(
        //   b"6F1D2A3B-0000-4000-8000-000000000001A1B2C3D4-0000-4000-8000-0000000000AA").digest()[:8], "big"))'
        XCTAssertEqual(BlobMigrationOrder.seed(deviceID: Self.deviceA, mediaID: "A1B2C3D4-0000-4000-8000-0000000000AA"),
                       7_244_292_921_441_912_339)
    }

    func testSeedOrdersEncryptingAndCiphertextOnlyTiersBeforeRecency() {
        let items = [item("old", created: 0), item("new", created: 100),
                     encrypting("oldVideo", created: 0), encrypting("newVideo", created: 100)]
        let seeds: [String: UInt64] = ["old": 1, "new": 2, "oldVideo": 1, "newVideo": 2]

        XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked) { seeds[$0] ?? 0 }),
                       ["oldVideo", "newVideo", "old", "new"])
    }

    func testDifferentDeviceSeedsStartOnDifferentItems() {
        for items in [distinctlyDated { item($0, created: $1) }, distinctlyDated { encrypting($0, created: $1) }] {
            let onA = ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked,
                                                  seed: BlobMigrationOrder.deviceSeed(deviceID: Self.deviceA)))
            let onB = ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked,
                                                  seed: BlobMigrationOrder.deviceSeed(deviceID: Self.deviceB)))

            XCTAssertEqual(Set(onA), Set(items.map(\.mediaID)))
            XCTAssertEqual(Set(onB), Set(items.map(\.mediaID)))
            XCTAssertNotEqual(onA.first, onB.first, "the two devices start on different items")
            XCTAssertNotEqual(onA, ids(order(items)), "the device seed, not recency, orders the tier")
        }
    }

    func testDeviceSeededOrderStableAcrossReload() throws {
        let defaults = makeIsolatedDefaults()
        let items = distinctlyDated { item($0, created: $1) } + distinctlyDated { encrypting("v\($0)", created: $1) }
        let plan = try MigrationPlan(id: MigrationPlan.albumPlanID,
                                     source: MigrationEndpoint(albumName: "Trip", storage: .icloud),
                                     destination: MigrationEndpoint(albumName: "Trip", storage: .cloudKit),
                                     scope: .album, items: items, createdAt: Self.base)
        let firstLaunch = BlobMigrationOrder.deviceSeed(deviceID: DeviceIdentity.currentID(defaults: defaults))
        let before = BlobMigrationOrder.next(items: plan.items, deviceState: .unlocked, seed: firstLaunch)

        let reloaded = try JSONDecoder().decode(MigrationPlan.self, from: JSONEncoder().encode(plan))
        let relaunch = BlobMigrationOrder.deviceSeed(deviceID: DeviceIdentity.currentID(defaults: defaults))
        let after = BlobMigrationOrder.next(items: reloaded.items, deviceState: .unlocked, seed: relaunch)

        XCTAssertEqual(after, before)
        XCTAssertNotEqual(ids(before), ids(order(items)), "precondition: the seed decides the order")
    }

    func testUserRequestedTierIgnoresDeviceSeed() {
        let items = [item("c", request: .userAction, requestedAt: 10),
                     item("b", request: .userAction, requestedAt: 10),
                     item("a", request: .userAction, requestedAt: 10),
                     item("first", request: .userAction, requestedAt: 5)]
        let reversing: [String: UInt64] = ["a": 3, "b": 2, "c": 1, "first": 9]

        let expected = ["first", "a", "b", "c"]
        XCTAssertEqual(ids(order(items)), expected)
        XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked) { reversing[$0] ?? 0 }),
                       expected, "request order, then mediaID, whatever the seed")
        for device in [Self.deviceA, Self.deviceB] {
            XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked,
                                                       seed: BlobMigrationOrder.deviceSeed(deviceID: device))),
                           expected)
        }
    }

    func testViewedTierIgnoresDeviceSeed() {
        let items = [item("c", request: .viewed, requestedAt: 10),
                     item("b", request: .viewed, requestedAt: 10),
                     item("a", request: .viewed, requestedAt: 10),
                     item("latest", request: .viewed, requestedAt: 20)]
        let reversing: [String: UInt64] = ["a": 3, "b": 2, "c": 1, "latest": 9]

        let expected = ["latest", "a", "b", "c"]
        XCTAssertEqual(ids(order(items)), expected)
        XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked) { reversing[$0] ?? 0 }),
                       expected, "most recently viewed, then mediaID, whatever the seed")
        for device in [Self.deviceA, Self.deviceB] {
            XCTAssertEqual(ids(BlobMigrationOrder.next(items: items, deviceState: .unlocked,
                                                       seed: BlobMigrationOrder.deviceSeed(deviceID: device))),
                           expected)
        }
    }

    // MARK: - Stored inputs

    func testOrderIsStableAcrossPlanReload() throws {
        let items = [
            encrypting("bigVideo", created: 70),
            item("photo", created: 60),
            item("viewed", request: .viewed, requestedAt: 40),
            item("requested", request: .userAction, requestedAt: 5),
            item("live", type: .photo, created: 65),
            item("live", type: .video, size: 4_000, created: 65),
            item("done", state: .sourceDeleted),
        ]
        let plan = try MigrationPlan(id: MigrationPlan.albumPlanID,
                                     source: MigrationEndpoint(albumName: "Trip", storage: .icloud),
                                     destination: MigrationEndpoint(albumName: "Trip", storage: .cloudKit),
                                     scope: .album, items: items, createdAt: Self.base)

        let reloaded = try JSONDecoder().decode(MigrationPlan.self, from: JSONEncoder().encode(plan))

        XCTAssertEqual(reloaded.items, plan.items)
        for state in [BlobMigrationDeviceState.locked, .unlocked] {
            XCTAssertEqual(order(reloaded.items, state), order(plan.items, state))
        }
    }

    func testPrioritizeCheckpointsThePlan() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobMigrationQueueOrderingTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plan.encplan")
        let key = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let livePhoto = item("live", type: .photo, created: 0)
        let liveVideo = item("live", type: .video, size: 4_000, created: 0)
        let plan = try MigrationPlan(id: MigrationPlan.albumPlanID,
                                     source: MigrationEndpoint(albumName: "Trip", storage: .icloud),
                                     destination: MigrationEndpoint(albumName: "Trip", storage: .cloudKit),
                                     scope: .album,
                                     items: [item("newest", created: 100), livePhoto, liveVideo, item("old", created: 1)],
                                     createdAt: Self.base)
        try await MigrationPlanStore(keyBytes: key, planURL: url).save(plan)

        try await MigrationPlanStore(keyBytes: key, planURL: url)
            .prioritize([livePhoto], reason: .userAction, at: date(10))
        try await MigrationPlanStore(keyBytes: key, planURL: url)
            .prioritize([item("old")], reason: .viewed, at: date(20))

        let loaded = await MigrationPlanStore(keyBytes: key, planURL: url).load()
        let reloaded = try XCTUnwrap(loaded)
        let byRecord = Dictionary(uniqueKeysWithValues: reloaded.items.map { ($0.recordName, $0) })
        XCTAssertEqual(byRecord[liveVideo.recordName]?.priorityRequest,
                       MigrationPriorityRequest(reason: .userAction, requestedAt: date(10)),
                       "both halves of a Live Photo are stamped")
        XCTAssertEqual(byRecord[livePhoto.recordName]?.priorityRequest?.reason, .userAction)
        XCTAssertEqual(byRecord[item("old").recordName]?.priorityRequest,
                       MigrationPriorityRequest(reason: .viewed, requestedAt: date(20)))
        XCTAssertNil(byRecord[item("newest").recordName]?.priorityRequest)
        XCTAssertEqual(ids(order(reloaded.items)), ["live", "live", "old", "newest"])

        let missing = dir.appendingPathComponent("absent.encplan")
        let none = try await MigrationPlanStore(keyBytes: key, planURL: missing)
            .prioritize([livePhoto], reason: .userAction)
        XCTAssertNil(none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "no plan, nothing written")
    }

    func testARequestNeverLowersAnItemsTier() {
        var requested = item("a")
        requested.recordPriorityRequest(.userAction, at: date(10))
        requested.recordPriorityRequest(.viewed, at: date(20))
        XCTAssertEqual(requested.priorityRequest, MigrationPriorityRequest(reason: .userAction, requestedAt: date(10)))
        requested.recordPriorityRequest(.userAction, at: date(30))
        XCTAssertEqual(requested.priorityRequest?.requestedAt, date(10), "a user request keeps its place in line")

        var viewed = item("b")
        viewed.recordPriorityRequest(.viewed, at: date(10))
        viewed.recordPriorityRequest(.viewed, at: date(40))
        XCTAssertEqual(viewed.priorityRequest?.requestedAt, date(40), "the most recent view counts")
        viewed.recordPriorityRequest(.userAction, at: date(50))
        XCTAssertEqual(viewed.priorityRequest, MigrationPriorityRequest(reason: .userAction, requestedAt: date(50)))
    }

    func testKindIsDerivedFromTypeAndSizeAtPlanTime() throws {
        XCTAssertEqual(item("v", type: .video, size: Self.large).kind, .encrypting)
        XCTAssertEqual(item("v", type: .video, size: Self.large + 1).kind, .encrypting)
        XCTAssertEqual(item("v", type: .video, size: Self.large - 1).kind, .ciphertextOnly)
        XCTAssertEqual(item("p", type: .photo, size: Self.large * 4).kind, .ciphertextOnly)
        XCTAssertEqual(item("v", type: .video, size: 0).kind, .ciphertextOnly)

        var planned = item("v", type: .video, size: Self.large)
        planned.sizeBytes = 10
        XCTAssertEqual(planned.kind, .encrypting, "the kind is set once, at plan time")
        let decoded = try JSONDecoder().decode(MigrationItem.self, from: JSONEncoder().encode(planned))
        XCTAssertEqual(decoded.kind, .encrypting, "a stored kind is read back, not re-derived")
    }

    @MainActor
    func testReplanKeepsAPendingItemsPriorityRequest() {
        let requested = item("a", state: .failed, request: .userAction, requestedAt: 10)
        let fresh = item("a")

        let merged = CloudKitMigrationManager.merge(existing: [requested], enumerated: [fresh])

        XCTAssertEqual(merged.first?.state, .pending)
        XCTAssertEqual(merged.first?.priorityRequest, requested.priorityRequest)
    }
}
