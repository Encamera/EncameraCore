//
//  CloudKitFoundationsTests.swift
//  EncameraCoreTests
//
//  Chunk 01 — CloudKit foundations. These tests never touch a live iCloud
//  account: account status and zone provisioning are injected via stubs.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class CloudKitFoundationsTests: XCTestCase {

    // MARK: - Stubs

    private struct StubAccountStatus: AccountStatusProviding {
        let status: CKAccountStatus
        func currentAccountStatus() async throws -> CKAccountStatus { status }
    }

    private final class CountingZoneProvisioner: RecordZoneProvisioning {
        private(set) var saveCount = 0
        private(set) var deletedZoneIDs: [CKRecordZone.ID] = []
        var deleteError: Error?
        func saveZone(_ zone: CKRecordZone) async throws { saveCount += 1 }
        func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
            deletedZoneIDs.append(zoneID)
            if let deleteError { throw deleteError }
        }
    }

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        makeIsolatedDefaults(name)
    }

    private func makeKeyedHandler(keyBytes: [UInt8]) -> SyncedStoreEncryptionHandler {
        let keyManager = DemoKeyManager()
        keyManager.currentKey = PrivateKey(name: "test", keyBytes: keyBytes, creationDate: Date())
        return SyncedStoreEncryptionHandler(keyManager: keyManager)
    }

    // MARK: - Schema constants are stable

    func testSchemaConstantsAreStable() {
        // One container shared by both bundle IDs; debug/prod isolation is by
        // CloudKit environment, not container.
        XCTAssertEqual(CloudKitSchema.containerID, "iCloud.app.encamera.Encamera")
        XCTAssertEqual(CloudKitSchema.zoneName, "EncameraZone")
        XCTAssertEqual(CloudKitSchema.EncMedia.recordType, "EncMedia")
        XCTAssertEqual(CloudKitSchema.EncMedia.albumID, "albumID")
        XCTAssertEqual(CloudKitSchema.EncMedia.mediaID, "mediaID")
        XCTAssertEqual(CloudKitSchema.EncMedia.mediaType, "mediaType")
        XCTAssertEqual(CloudKitSchema.EncMedia.createdAt, "createdAt")
        XCTAssertEqual(CloudKitSchema.EncMedia.sizeBytes, "sizeBytes")
        XCTAssertEqual(CloudKitSchema.EncMedia.creationDevice, "creationDeviceID")
        XCTAssertEqual(CloudKitSchema.EncMedia.schemaVersion, "schemaVersion")
        XCTAssertEqual(CloudKitSchema.EncMedia.encThumbnail, "encThumbnail")
        XCTAssertEqual(CloudKitSchema.EncMedia.encBlob, "encBlob")
    }

    // MARK: - Account status gating

    func testAccountStatusUnavailableFallsBackToLocal() async {
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .noAccount),
            zoneProvisioner: CountingZoneProvisioner(),
            defaults: freshDefaults()
        )

        let status = await container.accountStatus()
        XCTAssertEqual(status, .noAccount)

        let available = await container.isCloudKitAvailable()
        XCTAssertFalse(available)
    }

    func testAccountStatusAvailableReportsAvailable() async {
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: CountingZoneProvisioner(),
            defaults: freshDefaults()
        )
        let available = await container.isCloudKitAvailable()
        XCTAssertTrue(available)
    }

    // MARK: - Zone bootstrap idempotency

    func testEnsureZoneIsIdempotent() async throws {
        let provisioner = CountingZoneProvisioner()
        let defaults = freshDefaults()
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: defaults
        )

        try await container.ensureZoneExists()
        try await container.ensureZoneExists()
        try await container.ensureZoneExists()

        XCTAssertEqual(provisioner.saveCount, 1)
    }

    // MARK: - Teardown (Erase All Data)

    func testDeleteAllCloudDataDeletesZoneAndResetsFlag() async throws {
        let provisioner = CountingZoneProvisioner()
        let defaults = freshDefaults()
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: defaults
        )

        try await container.ensureZoneExists()
        XCTAssertEqual(provisioner.saveCount, 1)

        try await container.deleteAllCloudData()

        XCTAssertEqual(provisioner.deletedZoneIDs,
                       [container.zoneID, CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName)])

        try await container.ensureZoneExists()
        XCTAssertEqual(provisioner.saveCount, 2)
    }

    func testDeleteAllCloudDataTreatsZoneNotFoundAsSuccess() async throws {
        let provisioner = CountingZoneProvisioner()
        provisioner.deleteError = CKError(.zoneNotFound)
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: freshDefaults()
        )

        try await container.deleteAllCloudData()
        XCTAssertEqual(provisioner.deletedZoneIDs.count, 2)
    }

    func testDeleteAllCloudDataRethrowsRealError() async {
        let provisioner = CountingZoneProvisioner()
        provisioner.deleteError = CKError(.networkUnavailable)
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: freshDefaults()
        )

        do {
            try await container.deleteAllCloudData()
            XCTFail("Expected a non-benign CloudKit error to propagate")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkUnavailable)
        }
    }

    func testDeleteAllCloudDataClearsBothLatchesEvenWhenTheDeleteFails() async throws {
        let provisioner = CountingZoneProvisioner()
        let defaults = freshDefaults()
        let container = CloudKitContainer(
            accountStatusProvider: StubAccountStatus(status: .available),
            zoneProvisioner: provisioner,
            defaults: defaults
        )

        try await container.ensureZoneExists()
        defaults.set(true, forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)
        provisioner.deleteError = CKError(.requestRateLimited)

        do {
            try await container.deleteAllCloudData()
            XCTFail("Expected a non-benign CloudKit error to propagate")
        } catch {
            XCTAssertFalse(container.hasEverProvisionedZone)
            XCTAssertFalse(defaults.bool(forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey))
        }
    }

    // MARK: - albumID determinism

    func testAlbumIDIsDeterministic() throws {
        let keyBytes: [UInt8] = Array(0..<32).map { UInt8($0) }
        let handlerA = makeKeyedHandler(keyBytes: keyBytes)
        let handlerB = makeKeyedHandler(keyBytes: keyBytes)

        let albumName = "Vacation 2024"
        let hashA = try handlerA.hashPrimaryKey(albumName)
        let hashB = try handlerB.hashPrimaryKey(albumName)

        XCTAssertEqual(hashA, hashB)
        let other = try handlerA.hashPrimaryKey("Work")
        XCTAssertNotEqual(hashA, other)
    }

    // MARK: - InMemoryCloudKitMediaStore reassignAlbum

    /// Seed records under albumA, reassign to albumB, call fetchChanges, verify the
    /// changed metadata has albumB.
    func testReassignShowsUpInNextFetchChanges() async throws {
        let store = InMemoryCloudKitMediaStore()
        store.seedRecords(albumID: "albumA", mediaCount: 2)

        let names = ["albumA-seeded-0", "albumA-seeded-1"]
        let notFound = try await store.reassignAlbum(recordNames: names, toAlbumID: "albumB")
        XCTAssertTrue(notFound.isEmpty, "Both records exist, nothing should be not-found")

        let changes = try await store.fetchChanges(since: nil)
        let changedAlbumIDs = changes.changed.map(\.albumID)
        XCTAssertTrue(changedAlbumIDs.allSatisfy { $0 == "albumB" },
                      "Every record should now belong to albumB, got \(changedAlbumIDs)")
        XCTAssertEqual(changes.changed.count, 2)
    }

    /// Reassign a record name that does not exist in the InMemoryCloudKitMediaStore;
    /// verify it is returned as not-found.
    func testReassignInMemoryReturnsMissingNames() async throws {
        let store = InMemoryCloudKitMediaStore()
        let notFound = try await store.reassignAlbum(recordNames: ["nonexistent"], toAlbumID: "albumB")
        XCTAssertEqual(notFound, ["nonexistent"])
    }

    /// confirmAlbum uses the protocol extension and returns the current albumID.
    func testConfirmAlbumReturnsCurrentAlbumID() async throws {
        let store = InMemoryCloudKitMediaStore()
        store.seedRecords(albumID: "albumA", mediaCount: 1)

        let confirmed = try await store.confirmAlbum(recordName: "albumA-seeded-0")
        XCTAssertEqual(confirmed, "albumA")

        _ = try await store.reassignAlbum(recordNames: ["albumA-seeded-0"], toAlbumID: "albumB")
        let afterMove = try await store.confirmAlbum(recordName: "albumA-seeded-0")
        XCTAssertEqual(afterMove, "albumB")
    }

    /// confirmAlbum returns nil when the record does not exist.
    func testConfirmAlbumReturnsNilForMissingRecord() async throws {
        let store = InMemoryCloudKitMediaStore()
        let result = try await store.confirmAlbum(recordName: "no-such-record")
        XCTAssertNil(result)
    }
}
