//
//  CloudKitMediaStoreTests.swift
//  EncameraCoreTests
//
//  Chunk 02 — exercises CloudKitMediaStore against an in-memory mock adapter.
//  No network, no iCloud account.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class CloudKitMediaStoreTests: XCTestCase {

    // Reference box so a @Sendable progress closure can accumulate values.
    private final class Box: @unchecked Sendable { var values: [Double] = [] }

    private let tokenKey = "cloudkit_zone_change_token_v1"
    private let longLivedMapKey = "cloudkit_longlived_ops_v1"

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.cloudkit.store.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(account: CKAccountStatus = .available,
                           adapter: MockCloudKitDatabase,
                           defaults: UserDefaults) -> CloudKitMediaStore {
        let container = CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: account),
                                          zoneProvisioner: StubZoneProvisioner(),
                                          defaults: defaults)
        return CloudKitMediaStore(container: container, adapter: adapter, defaults: defaults, recoverOnInit: false)
    }

    private func makeUpload(mediaID: String = "media-1",
                            albumID: String = "album-hash",
                            mediaType: MediaType = .video,
                            fileURL: URL = URL(fileURLWithPath: "/tmp/enc.blob"),
                            thumbURL: URL = URL(fileURLWithPath: "/tmp/enc.thumb")) -> CloudKitMediaUpload {
        CloudKitMediaUpload(albumID: albumID,
                            mediaID: mediaID,
                            mediaType: mediaType,
                            createdAt: Date(timeIntervalSince1970: 555),
                            sizeBytes: 4096,
                            encryptedFileURL: fileURL,
                            encryptedThumbURL: thumbURL)
    }

    // MARK: - Upload

    func testUploadBuildsRecordWithBothAssetsAndIndexFields() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        let fileURL = URL(fileURLWithPath: "/tmp/enc-\(UUID()).blob")
        let thumbURL = URL(fileURLWithPath: "/tmp/enc-\(UUID()).thumb")

        let ref = try await store.upload(makeUpload(fileURL: fileURL, thumbURL: thumbURL), progress: { _ in })
        XCTAssertEqual(ref.recordName, "media-1")

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.albumID] as? String, "album-hash")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.mediaID] as? String, "media-1")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.mediaType] as? Int64, Int64(MediaType.video.rawValue))
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.sizeBytes] as? Int64, 4096)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.schemaVersion] as? Int64, CloudKitSchema.currentSchemaVersion)

        let blob = saved[CloudKitSchema.EncMedia.encBlob] as? CKAsset
        let thumb = saved[CloudKitSchema.EncMedia.encThumbnail] as? CKAsset
        XCTAssertEqual(blob?.fileURL, fileURL)
        XCTAssertEqual(thumb?.fileURL, thumbURL)

        XCTAssertEqual(mock.lastSavePolicy?.rawValue,
                       CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged.rawValue)
        XCTAssertEqual(mock.lastSaveLongLived, true)
    }

    func testUploadReportsProgressMonotonic0to1() async throws {
        let mock = MockCloudKitDatabase()
        mock.saveProgressValues = [0.0, 0.4, 1.0]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let box = Box()
        _ = try await store.upload(makeUpload(), progress: { box.values.append($0) })

        XCTAssertEqual(box.values, [0.0, 0.4, 1.0])
        XCTAssertEqual(box.values.last, 1.0)
    }

    func testAccountUnavailableShortCircuits() async {
        let mock = MockCloudKitDatabase()
        let store = makeStore(account: .noAccount, adapter: mock, defaults: freshDefaults())

        do {
            _ = try await store.upload(makeUpload(), progress: { _ in })
            XCTFail("Expected accountUnavailable")
        } catch let error as CloudKitMediaStoreError {
            guard case .accountUnavailable = error else { return XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(mock.saveCount, 0, "No op should be issued when the account is unavailable")
    }

    // MARK: - Metadata sync

    func testFetchMetadataExcludesBlobAsset() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let withoutThumb = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(withoutThumb.count, 1)
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encBlob), false)
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encThumbnail), false)

        _ = try await store.fetchMetadata(albumID: "a1", includeThumbnail: true)
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encBlob), false,
                       "encBlob must never be eagerly requested")
        XCTAssertEqual(mock.lastQueryDesiredKeys?.contains(CloudKitSchema.EncMedia.encThumbnail), true)
    }

    func testFetchMetadataFiltersTombstones() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1"),
            CloudKitTestFactory.encMediaRecord(recordName: "m2", albumID: "a1", deletedAt: Date())
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let meta = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(meta.map { $0.recordName }, ["m1"])
    }

    // MARK: - Lazy asset fetch

    func testFetchBlobCopiesOutOfTempURL() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ck-temp-\(UUID()).bin")
        let payload = Data("ciphertext".utf8)
        try payload.write(to: temp)

        let record = CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: temp)

        let mock = MockCloudKitDatabase()
        mock.stubbedFetchRecords = [CloudKitTestFactory.recordID("m1"): record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ck-dest-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        try await store.fetchBlob(recordName: "m1", to: dest, progress: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        // The copy must survive deletion of CloudKit's temp file.
        try FileManager.default.removeItem(at: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), payload)

        XCTAssertEqual(mock.lastFetchDesiredKeys, [CloudKitSchema.EncMedia.encBlob])
    }

    // MARK: - Delete / tombstone

    func testDeleteIsAtomicSingleOp() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.delete(recordName: "m1")

        XCTAssertEqual(mock.deleteCount, 1)
        XCTAssertEqual(mock.fetchCount, 0, "No separate blob op — delete removes the record and both assets atomically")
        XCTAssertEqual(mock.deletedRecordIDBatches.first?.first, CloudKitTestFactory.recordID("m1"))
    }

    func testTombstoneSetsDeletedAtAndSaves() async throws {
        let record = CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")
        let mock = MockCloudKitDatabase()
        mock.stubbedFetchRecords = [CloudKitTestFactory.recordID("m1"): record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.tombstone(recordName: "m1")

        XCTAssertEqual(mock.fetchCount, 1)
        let saved = try XCTUnwrap(mock.savedRecordBatches.last?.first)
        XCTAssertNotNil(saved[CloudKitSchema.EncMedia.deletedAt] as? Date)
    }

    // MARK: - Error mapping

    func testQuotaExceededMapsToNonRetryable() {
        let mapped = mapCKError(CKErrorFactory.error(.quotaExceeded))
        guard case .quotaExceeded = mapped else { return XCTFail("Expected quotaExceeded, got \(mapped)") }
        XCTAssertFalse(mapped.isRetryable)
    }

    func testRetryAfterIsParsed() {
        let mapped = mapCKError(CKErrorFactory.error(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 7.0]))
        guard case .retry(let after) = mapped else { return XCTFail("Expected retry, got \(mapped)") }
        XCTAssertEqual(after, 7.0)
        XCTAssertTrue(mapped.isRetryable)
    }

    func testPartialFailureKeepsSucceeded() {
        let itemError = CKErrorFactory.error(.serverRecordChanged)
        let mapped = mapCKError(CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CloudKitTestFactory.recordID("m1"): itemError]]
        ))
        guard case .partial(let failed) = mapped else { return XCTFail("Expected partial, got \(mapped)") }
        XCTAssertNotNil(failed["m1"], "The failed record must be reported")
        XCTAssertNil(failed["m2"], "Records not in partialErrors are considered succeeded")
    }

    func testZoneNotFoundMaps() {
        guard case .zoneNotFound = mapCKError(CKErrorFactory.error(.zoneNotFound)) else {
            return XCTFail("Expected zoneNotFound")
        }
        guard case .zoneNotFound = mapCKError(CKErrorFactory.error(.userDeletedZone)) else {
            return XCTFail("Expected zoneNotFound for userDeletedZone")
        }
    }

    func testChangeTokenExpiredMaps() {
        guard case .changeTokenExpired = mapCKError(CKErrorFactory.error(.changeTokenExpired)) else {
            return XCTFail("Expected changeTokenExpired")
        }
    }

    func testZoneScopedErrorsWrappedInPartialFailureUnwrap() {
        // CloudKit delivers zone-scoped errors at the op level wrapped in
        // `.partialFailure` — the typed cases must still come out, or the
        // token-expired full-resync and zone recreation never fire.
        let zoneID = CKRecordZone.ID(zoneName: CloudKitSchema.zoneName)
        let wrappedToken = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [zoneID: CKErrorFactory.error(.changeTokenExpired)]]
        )
        guard case .changeTokenExpired = mapCKError(wrappedToken) else {
            return XCTFail("Expected changeTokenExpired out of a wrapped partial failure")
        }
        let wrappedZone = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [zoneID: CKErrorFactory.error(.zoneNotFound)]]
        )
        guard case .zoneNotFound = mapCKError(wrappedZone) else {
            return XCTFail("Expected zoneNotFound out of a wrapped partial failure")
        }
        // A mixed bag must still surface as partial, not be misread as zone-scoped.
        let mixed = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [
                CloudKitTestFactory.recordID("m1"): CKErrorFactory.error(.serverRecordChanged),
                CloudKitTestFactory.recordID("m2"): CKErrorFactory.error(.changeTokenExpired)
            ] as [AnyHashable: Error]]
        )
        guard case .partial = mapCKError(mixed) else {
            return XCTFail("Expected partial for heterogeneous failures")
        }
    }

    func testFetchChangesRecognizesTokenExpiryWrappedInPartialFailure() async {
        let mock = MockCloudKitDatabase()
        let zoneID = CKRecordZone.ID(zoneName: CloudKitSchema.zoneName)
        mock.zoneChangesError = CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [zoneID: CKErrorFactory.error(.changeTokenExpired)]]
        )
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        do {
            _ = try await store.fetchChanges(since: nil)
            XCTFail("Expected changeTokenExpired")
        } catch let error as CloudKitMediaStoreError {
            guard case .changeTokenExpired = error else { return XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testZoneNotFoundInvalidatesZoneAndSubscriptionFlags() async throws {
        let defaults = freshDefaults()
        let zoneKey = "cloudkit_zone_created_v1_" + CloudKitSchema.containerID
        let subKey = "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID
        defaults.set(true, forKey: zoneKey)
        defaults.set(true, forKey: subKey)

        let mock = MockCloudKitDatabase()
        mock.zoneChangesError = CKErrorFactory.error(.zoneNotFound)
        let store = makeStore(adapter: mock, defaults: defaults)

        do {
            _ = try await store.fetchChanges(since: nil)
            XCTFail("Expected zoneNotFound")
        } catch let error as CloudKitMediaStoreError {
            guard case .zoneNotFound = error else { return XCTFail("Wrong error: \(error)") }
        }

        XCTAssertFalse(defaults.bool(forKey: zoneKey),
                       "A gone zone must clear the zone-created flag so ensureZoneExists() re-provisions")
        XCTAssertFalse(defaults.bool(forKey: subKey),
                       "A gone zone must clear the subscription flag so registration re-runs")

        // With the stale flag cleared, registration actually happens again.
        try await store.registerZoneSubscription()
        XCTAssertEqual(mock.savedSubscriptions.count, 1)
    }

    func testCancelledErrorMaps() {
        guard case .cancelled = mapCKError(CKErrorFactory.error(.operationCancelled)) else {
            return XCTFail("Expected cancelled")
        }
    }

    func testNotAuthenticatedMapsToAccountUnavailable() {
        guard case .accountUnavailable = mapCKError(CKErrorFactory.error(.notAuthenticated)) else {
            return XCTFail("Expected accountUnavailable")
        }
    }

    // MARK: - Cancellation

    func testCancelAllInvokesAdapter() {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        store.cancelAll()
        XCTAssertTrue(mock.cancelAllCalled)
    }

    // MARK: - Delta sync

    func testFetchChangesMapsChangedAndDeleted() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedZoneChanges = ZoneChangesResult(
            changed: [CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")],
            deletedRecordNames: ["m2"],
            token: nil,
            moreComing: true
        )
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let changeSet = try await store.fetchChanges(since: nil)
        XCTAssertEqual(changeSet.changed.map { $0.recordName }, ["m1"])
        XCTAssertEqual(changeSet.deleted, ["m2"])
        XCTAssertTrue(changeSet.moreComing)
    }

    func testFetchChangesDoesNotPersistTokenOnFailure() async {
        let defaults = freshDefaults()
        let sentinel = Data([1, 2, 3])
        defaults.set(sentinel, forKey: tokenKey)

        let mock = MockCloudKitDatabase()
        mock.zoneChangesError = CKErrorFactory.error(.networkUnavailable)
        let store = makeStore(adapter: mock, defaults: defaults)

        do {
            _ = try await store.fetchChanges(since: nil)
            XCTFail("Expected a thrown error")
        } catch {
            // expected
        }
        XCTAssertEqual(defaults.data(forKey: tokenKey), sentinel,
                       "A failed fetch must not advance the persisted change token")
    }

    // MARK: - Long-lived recovery

    func testLongLivedRecoveryReattachesFromOurMap() async {
        let defaults = freshDefaults()
        defaults.set(["m1": "opA", "m2": "opB"], forKey: longLivedMapKey)

        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: defaults)

        await store.recoverLongLivedOperations()

        XCTAssertEqual(Set(mock.reattachedIDs), Set(["opA", "opB"]))
    }
}
