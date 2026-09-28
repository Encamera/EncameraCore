//
//  CloudKitMigrationPlanTests.swift
//  EncameraCoreTests
//
//  The migration plan is the durable checkpoint that makes a transfer between local
//  storage and CloudKit resumable across a crash/kill. These tests pin its shape
//  (endpoints, scope, direction), its byte-weighted progress math, where plans live
//  on disk, and the encrypted, atomic, crash-safe persistence envelope.
//

import XCTest
import CryptoKit
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

    private func makePlan(items: [MigrationItem], cancelledAt: Date? = nil) -> MigrationPlan {
        try! MigrationPlan(
            id: MigrationPlan.albumPlanID,
            source: MigrationEndpoint(albumName: "Vacation", storage: .local),
            destination: MigrationEndpoint(albumName: "Vacation", storage: .cloudKit),
            scope: .album,
            items: items,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            cancelledAt: cancelledAt
        )
    }

    private func makeItemPlan(id: String = UUID().uuidString,
                              source: MigrationEndpoint = MigrationEndpoint(albumName: "Src", storage: .cloudKit),
                              destination: MigrationEndpoint = MigrationEndpoint(albumName: "Dst", storage: .local),
                              items: [MigrationItem] = [],
                              cancelledAt: Date? = nil) -> MigrationPlan {
        try! MigrationPlan(id: id, source: source, destination: destination, scope: .items,
                           items: items, createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                           cancelledAt: cancelledAt)
    }

    private func makeAlbum(name: String = "Album-\(UUID().uuidString)", storage: StorageType = .local) -> Album {
        Album(name: name,
              storageOption: storage,
              creationDate: Date(timeIntervalSinceReferenceDate: 700_000_000),
              key: PrivateKey(name: "key-\(name)", keyBytes: randomKey(),
                              creationDate: Date(timeIntervalSinceReferenceDate: 700_000_000)))
    }

    private func removePlans(_ albums: Album...) {
        for album in albums {
            try? FileManager.default.removeItem(at: MigrationPlanStore.directoryURL(forSource: album))
        }
    }

    // MARK: - Shape

    func testDirectionFollowsTheSourceStorage() {
        XCTAssertEqual(makePlan(items: []).direction, .toCloudKit)
        XCTAssertEqual(makeItemPlan(source: MigrationEndpoint(albumName: "A", storage: .icloud),
                                    destination: MigrationEndpoint(albumName: "B", storage: .cloudKit)).direction,
                       .toCloudKit)
        XCTAssertEqual(makeItemPlan().direction, .toLocal)
    }

    func testRejectsStoragePairsThatAreNotATransfer() {
        let pairs: [(StorageType, StorageType)] = [
            (.local, .local), (.cloudKit, .cloudKit), (.icloud, .local),
            (.cloudKit, .icloud), (.local, .icloud), (.icloud, .icloud),
        ]
        for (source, destination) in pairs {
            XCTAssertThrowsError(try MigrationPlan(id: "x",
                                                   source: MigrationEndpoint(albumName: "A", storage: source),
                                                   destination: MigrationEndpoint(albumName: "B", storage: destination),
                                                   scope: .items, items: [], createdAt: Date()),
                                 "\(source) -> \(destination) must be rejected") { error in
                XCTAssertEqual(error as? MigrationPlanError,
                               .unsupportedStoragePair(source: source, destination: destination))
            }
        }
    }

    func testAlbumScopeRequiresOneAlbumNameAndTheAlbumPlanID() {
        XCTAssertThrowsError(try MigrationPlan(id: MigrationPlan.albumPlanID,
                                               source: MigrationEndpoint(albumName: "A", storage: .local),
                                               destination: MigrationEndpoint(albumName: "B", storage: .cloudKit),
                                               scope: .album, items: [], createdAt: Date())) { error in
            XCTAssertEqual(error as? MigrationPlanError, .invalidAlbumScope)
        }
        XCTAssertThrowsError(try MigrationPlan(id: UUID().uuidString,
                                               source: MigrationEndpoint(albumName: "A", storage: .local),
                                               destination: MigrationEndpoint(albumName: "A", storage: .cloudKit),
                                               scope: .album, items: [], createdAt: Date())) { error in
            XCTAssertEqual(error as? MigrationPlanError, .invalidAlbumScope)
        }
    }

    func testAlbumFactoryPicksTheOtherPlane() throws {
        let local = makeAlbum(name: "Trip", storage: .local)
        let forward = try MigrationPlan.album(local, items: [])
        XCTAssertEqual(forward.scope, .album)
        XCTAssertEqual(forward.id, MigrationPlan.albumPlanID)
        XCTAssertEqual(forward.destination, MigrationEndpoint(albumName: "Trip", storage: .cloudKit))

        var cloud = local
        cloud.storageOption = .cloudKit
        let reverse = try MigrationPlan.album(cloud, items: [])
        XCTAssertEqual(reverse.destination, MigrationEndpoint(albumName: "Trip", storage: .local))
        XCTAssertEqual(reverse.direction, .toLocal)
    }

    func testItemFactoryExpandsALivePhotoIntoTwoItems() throws {
        let source = makeAlbum(storage: .local)
        let destination = makeAlbum(storage: .cloudKit)
        let live = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(URL(fileURLWithPath: "/dev/null")), mediaType: .photo, id: "live"),
            EncryptedMedia(source: .url(URL(fileURLWithPath: "/dev/null")), mediaType: .video, id: "live"),
        ])
        let photo = try InteractableMedia(underlyingMedia: [
            EncryptedMedia(source: .url(URL(fileURLWithPath: "/dev/null")), mediaType: .photo, id: "still"),
        ])

        let plan = try MigrationPlan.items(source: source, destination: destination, media: [live, photo])

        XCTAssertEqual(plan.scope, .items)
        XCTAssertEqual(plan.items.map(\.recordName).sorted(),
                       [MediaRecordName.componentRecordName(mediaID: "live", type: .photo),
                        MediaRecordName.componentRecordName(mediaID: "live", type: .video),
                        MediaRecordName.componentRecordName(mediaID: "still", type: .photo)].sorted())
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .pending })
    }

    func testCodableRoundTripOfBothScopesKeepsEveryField() throws {
        let cancelled = Date(timeIntervalSinceReferenceDate: 750_000_000)
        for plan in [makePlan(items: [makeItem(state: .verified)], cancelledAt: cancelled),
                     makeItemPlan(items: [makeItem(state: .uploaded)], cancelledAt: cancelled)] {
            let decoded = try JSONDecoder().decode(MigrationPlan.self, from: JSONEncoder().encode(plan))
            XCTAssertEqual(decoded.id, plan.id)
            XCTAssertEqual(decoded.source, plan.source)
            XCTAssertEqual(decoded.destination, plan.destination)
            XCTAssertEqual(decoded.scope, plan.scope)
            XCTAssertEqual(decoded.direction, plan.direction)
            XCTAssertEqual(decoded.items, plan.items)
            XCTAssertEqual(decoded.version, MigrationPlan.currentVersion)
            XCTAssertEqual(try XCTUnwrap(decoded.cancelledAt).timeIntervalSinceReferenceDate,
                           cancelled.timeIntervalSinceReferenceDate, accuracy: 0.001)
        }
    }

    // MARK: - Progress math

    func testByteWeightedFractionUsesVerifiedAndDeletedOnly() {
        let plan = makePlan(items: [
            makeItem(size: 100, state: .verified),
            makeItem(size: 300, state: .sourceDeleted),
            makeItem(size: 600, state: .uploading),
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
            makeItem(state: .skipped),
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
        XCTAssertEqual(loaded?.source, MigrationEndpoint(albumName: "Vacation", storage: .local))
        XCTAssertEqual(loaded?.destination, MigrationEndpoint(albumName: "Vacation", storage: .cloudKit))
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

    // MARK: - Location

    func testPlansLiveUnderTheSourceAlbumsHashByID() {
        let album = makeAlbum(name: "Vacation", storage: .local)
        let hash = SHA256.hash(data: Data(album.id.utf8)).map { String(format: "%02x", $0) }.joined()

        XCTAssertTrue(MigrationPlanStore.planURL(sourceAlbum: album, planID: "move-1").path
            .hasSuffix("CloudKitMigration/\(hash)/move-1.encplan"))
        XCTAssertTrue(MigrationPlanStore.planURL(for: album).path
            .hasSuffix("CloudKitMigration/\(hash)/album.encplan"))
    }

    func testForwardAndReversePlansOfOneAlbumNameDoNotCollide() {
        let local = makeAlbum(name: "Same", storage: .local)
        var cloud = local
        cloud.storageOption = .cloudKit
        XCTAssertNotEqual(MigrationPlanStore.planURL(for: local), MigrationPlanStore.planURL(for: cloud))
    }

    func testPlansForListsOnlyThatSourcesPlansInBothScopes() async throws {
        let albumA = makeAlbum(storage: .local)
        let albumB = makeAlbum(storage: .local)
        defer { removePlans(albumA, albumB) }

        try await MigrationPlanStore(album: albumA).save(try MigrationPlan.album(albumA, items: [makeItem()]))
        let move = makeItemPlan(id: "move-a",
                                source: MigrationEndpoint(album: albumA),
                                destination: MigrationEndpoint(albumName: "Elsewhere", storage: .cloudKit),
                                items: [makeItem()])
        try await MigrationPlanStore(sourceAlbum: albumA, planID: move.id).save(move)
        try await MigrationPlanStore(album: albumB).save(try MigrationPlan.album(albumB, items: [makeItem()]))

        let plansA = await MigrationPlanStore.plans(for: albumA)
        XCTAssertEqual(Set(plansA.map(\.id)), [MigrationPlan.albumPlanID, "move-a"])
        XCTAssertEqual(Set(plansA.map(\.scope)), [.album, .items])

        let plansB = await MigrationPlanStore.plans(for: albumB)
        XCTAssertEqual(plansB.map(\.source), [MigrationEndpoint(album: albumB)])
    }

    func testClearAllPlansRemovesEveryPlan() async throws {
        let album = makeAlbum(storage: .local)
        try await MigrationPlanStore(album: album).save(try MigrationPlan.album(album, items: [makeItem()]))

        try MigrationPlanStore.clearAllPlans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: MigrationPlanStore.directoryURL().path))
        let plans = await MigrationPlanStore.plans(for: album)
        XCTAssertTrue(plans.isEmpty)
    }

    // MARK: - Superseded checkpoints

    /// Writes `json` encrypted with `key` at `url`, as an earlier build would have.
    private func writeEncrypted(_ json: [String: Any], key: [UInt8], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MediaIndexStore.encrypt(data, keyBytes: key).write(to: url)
    }

    private func legacyItemJSON() -> [String: Any] {
        ["mediaID": "a", "recordName": "a#0", "mediaType": 0, "createdAt": 0,
         "sizeBytes": 10, "state": "pending"]
    }

    func testVersionOnePlanReadsAsAbsentAndIsRemoved() async throws {
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: bundledFixtureURL(version: 1), to: url)

        let loaded = await MigrationPlanStore(keyBytes: Self.goldenKey, planURL: url).load()

        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an unloadable version-1 checkpoint is deleted")
    }

    func testMediaMovePlanShapedFileReadsAsAbsentAndIsRemoved() async throws {
        let key = randomKey()
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeEncrypted([
            "id": "move", "version": 1, "direction": "localToCloudKit",
            "source": ["name": "A", "storage": "local"],
            "destination": ["name": "B", "storage": "cloudKit"],
            "migration": ["albumName": "A", "sourceStorage": "local", "items": [legacyItemJSON()],
                          "createdAt": 0, "version": 1],
        ], key: key, to: url)

        let loaded = await MigrationPlanStore(keyBytes: key, planURL: url).load()

        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPlanWithAnInvalidStoragePairReadsAsAbsentAndIsRemoved() async throws {
        let key = randomKey()
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeEncrypted([
            "id": "x", "version": MigrationPlan.currentVersion, "scope": "items", "createdAt": 0, "items": [],
            "source": ["albumName": "A", "storage": "local"],
            "destination": ["albumName": "B", "storage": "local"],
        ], key: key, to: url)

        let loaded = await MigrationPlanStore(keyBytes: key, planURL: url).load()

        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPlansForRemovesTheVersionOneLayout() async throws {
        let album = makeAlbum(storage: .local)
        defer { removePlans(album) }
        let hash = SHA256.hash(data: Data(album.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = MigrationPlanStore.directoryURL()
        let oldAlbumPlan = root.appendingPathComponent("\(hash).encplan")
        let oldMoveDir = root.appendingPathComponent("moves/\(hash)", isDirectory: true)
        try writeEncrypted(["version": 1], key: album.key.keyBytes, to: oldAlbumPlan)
        try writeEncrypted(["version": 1], key: album.key.keyBytes, to: oldMoveDir.appendingPathComponent("m.encplan"))

        let plans = await MigrationPlanStore.plans(for: album)

        XCTAssertTrue(plans.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAlbumPlan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMoveDir.path))
    }

    func testWrongKeyReadsAsAbsentButIsKept() async throws {
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await MigrationPlanStore(keyBytes: randomKey(), planURL: url).save(makePlan(items: [makeItem()]))

        let loaded = await MigrationPlanStore(keyBytes: randomKey(), planURL: url).load()

        XCTAssertNil(loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a plan this key cannot decrypt may belong to another key's album")
    }

    // MARK: - Golden file (format stability)

    /// A known key and plan that produce the committed fixture. The key is
    /// deterministic (repeating 0x42) so the fixture can be regenerated if
    /// the encryption envelope ever needs to change intentionally.
    private static let goldenKey: [UInt8] = Array(repeating: 0x42, count: 32)

    private func goldenPlan() -> MigrationPlan {
        try! MigrationPlan(
            id: "golden-move",
            source: MigrationEndpoint(albumName: "GoldenSource", storage: .cloudKit),
            destination: MigrationEndpoint(albumName: "GoldenDestination", storage: .local),
            scope: .items,
            items: [
                MigrationItem(
                    mediaID: "golden-photo",
                    recordName: "golden-photo#photo",
                    mediaType: .photo,
                    createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                    sizeBytes: 1024,
                    state: .verified
                ),
                MigrationItem(
                    mediaID: "golden-video",
                    recordName: "golden-video#video",
                    mediaType: .video,
                    createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                    sizeBytes: 2048,
                    state: .sourceDeleted
                ),
            ],
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            cancelledAt: Date(timeIntervalSinceReferenceDate: 710_000_000)
        )
    }

    /// Where the fixture lives in the source tree. Only the generator writes here:
    /// Xcode Cloud runs tests on machines without the repository checked out.
    private func sourceFixtureURL(version: Int = MigrationPlan.currentVersion) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("migration-plan-v\(version).encplan")
    }

    /// The fixture as shipped in the test bundle. The app-hosted Xcode target
    /// flattens it to the bundle root; other hosts keep the Fixtures folder.
    private func bundledFixtureURL(version: Int = MigrationPlan.currentVersion) throws -> URL {
        let name = "migration-plan-v\(version)"
        let testBundle = Bundle(for: Self.self)
        let candidates = [
            testBundle.url(forResource: name, withExtension: "encplan"),
            testBundle.url(forResource: name, withExtension: "encplan", subdirectory: "Fixtures")
        ]
        return try XCTUnwrap(candidates.compactMap { $0 }.first, "Missing fixture \(name).encplan in the test bundle")
    }

    /// Generates the golden fixture for the current version. Run manually with
    /// `GENERATE_GOLDEN_FIXTURE=1` to create or refresh it — the normal test reads
    /// it without regenerating.
    func testGenerateGoldenFixture() async throws {
        guard ProcessInfo.processInfo.environment["GENERATE_GOLDEN_FIXTURE"] == "1" else {
            throw XCTSkip("Set GENERATE_GOLDEN_FIXTURE=1 to regenerate the fixture")
        }
        let url = sourceFixtureURL()
        try await MigrationPlanStore(keyBytes: Self.goldenKey, planURL: url).save(goldenPlan())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fixture written to \(url.path)")
    }

    /// Pins the on-disk format: the committed fixture must keep loading.
    func testGoldenFixtureLoads() async throws {
        let fixtureURL = try bundledFixtureURL()
        // Load a copy: an unloadable fixture would otherwise be deleted by `load()`.
        let url = try makeTempPlanURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: fixtureURL, to: url)

        let loaded = await MigrationPlanStore(keyBytes: Self.goldenKey, planURL: url).load()
        let plan = try XCTUnwrap(loaded)

        XCTAssertEqual(plan.id, "golden-move")
        XCTAssertEqual(plan.source, MigrationEndpoint(albumName: "GoldenSource", storage: .cloudKit))
        XCTAssertEqual(plan.destination, MigrationEndpoint(albumName: "GoldenDestination", storage: .local))
        XCTAssertEqual(plan.scope, .items)
        XCTAssertEqual(plan.items, goldenPlan().items)
        XCTAssertEqual(plan.cancelledAt, goldenPlan().cancelledAt)
        XCTAssertEqual(plan.version, MigrationPlan.currentVersion)
    }
}
