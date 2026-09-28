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
    private final class Box: @unchecked Sendable { var values: [Double] = [] }

    private let tokenKey = "cloudkit_zone_change_token_v1"
    private let longLivedMapKey = "cloudkit_longlived_ops_v1"

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        makeIsolatedDefaults(name)
    }

    private func makeStore(account: CKAccountStatus = .available,
                           adapter: MockCloudKitDatabase,
                           defaults: UserDefaults) -> CloudKitMediaStore {
        let container = CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: account),
                                          zoneProvisioner: StubZoneProvisioner(),
                                          defaults: defaults)
        return CloudKitMediaStore(container: container, adapter: adapter, defaults: defaults)
    }

    private func makeUpload(mediaID: String = "media-1",
                            albumID: String = "album-hash",
                            mediaType: MediaType = .video,
                            fileURL: URL = URL(fileURLWithPath: "/tmp/enc.blob"),
                            thumbURL: URL = URL(fileURLWithPath: "/tmp/enc.thumb"),
                            recordName: String? = nil,
                            keyFingerprint: String = "") -> CloudKitMediaUpload {
        CloudKitMediaUpload(albumID: albumID,
                            mediaID: mediaID,
                            mediaType: mediaType,
                            createdAt: Date(timeIntervalSince1970: 555),
                            sizeBytes: 4096,
                            encryptedFileURL: fileURL,
                            encryptedThumbURL: thumbURL,
                            recordName: recordName,
                            keyFingerprint: keyFingerprint)
    }

    /// Writes real ciphertext on disk, cleaned up when the test ends. The store
    /// snapshots the preview before uploading it, which it can only do when the
    /// file actually exists.
    private func makeCiphertextFile(_ name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckmediastore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    /// Real keys, so assertions use the same fingerprint production writes
    /// (`PrivateKey.keychainLabel`).
    private let keyA = PrivateKey(name: "keyA",
                                  keyBytes: Array(repeating: 0x42, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB",
                                  keyBytes: Array(repeating: 0x24, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 0))

    // MARK: - Upload

    /// Every record names its key. No build has ever shipped CloudKit, so an
    /// unlabelled record is not a state the zone can legitimately be in.
    func testUploadAlwaysWritesTheKeyFingerprint() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter, defaults: freshDefaults())
        _ = try await store.upload(makeUpload(keyFingerprint: keyA.keychainLabel), progress: { _ in })

        let record = try XCTUnwrap(adapter.savedRecordBatches.last?.first)
        XCTAssertEqual(record[CloudKitSchema.EncMedia.keyFingerprint] as? String, keyA.keychainLabel)
    }

    func testSaveAlbumAlwaysWritesTheKeyFingerprint() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter, defaults: freshDefaults())
        try await store.saveAlbum(CloudKitAlbumUpload(albumID: "album-hash",
                                                      encName: "Album_x",
                                                      createdAt: Date(),
                                                      isHidden: false,
                                                      keyFingerprint: keyB.keychainLabel))

        let record = try XCTUnwrap(adapter.savedRecordBatches.last?.first)
        XCTAssertEqual(record[CloudKitSchema.EncAlbum.keyFingerprint] as? String, keyB.keychainLabel)
    }


    func testUploadBuildsRecordWithBothAssetsAndIndexFields() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        let blobBytes = Data("blob-ciphertext".utf8)
        let thumbBytes = Data("preview-ciphertext".utf8)
        let fileURL = try makeCiphertextFile("enc.blob", contents: blobBytes)
        let thumbURL = try makeCiphertextFile("enc.thumb", contents: thumbBytes)

        let ref = try await store.upload(makeUpload(fileURL: fileURL, thumbURL: thumbURL), progress: { _ in })
        XCTAssertEqual(ref.recordName, "media-1")

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.albumID] as? String, "album-hash")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.mediaID] as? String, "media-1")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.mediaType] as? Int64, Int64(MediaType.video.rawValue))
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.sizeBytes] as? Int64, 4096)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.createdAt] as? Date, Date(timeIntervalSince1970: 555))
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.schemaVersion] as? Int64, CloudKitSchema.currentSchemaVersion)

        let blob = try XCTUnwrap(saved[CloudKitSchema.EncMedia.encBlob] as? CKAsset)
        XCTAssertEqual(blob.fileURL, fileURL, "The blob uploads straight from the encrypted file")
        XCTAssertEqual(mock.lastSavedAssetPayloads[CloudKitSchema.EncMedia.encBlob], blobBytes)

        let thumb = try XCTUnwrap(saved[CloudKitSchema.EncMedia.encThumbnail] as? CKAsset)
        let thumbAssetURL = try XCTUnwrap(thumb.fileURL)
        XCTAssertNotEqual(thumbAssetURL, thumbURL,
                          "The thumbnail must upload from a snapshot, not from the live preview file")
        XCTAssertEqual(mock.lastSavedAssetPayloads[CloudKitSchema.EncMedia.encThumbnail], thumbBytes,
                       "The snapshot must carry the preview's bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbAssetURL.path),
                       "The snapshot is the upload's alone and must not outlive it")

        let albumRef = try XCTUnwrap(saved[CloudKitSchema.EncMedia.albumRef] as? CKRecord.Reference)
        XCTAssertEqual(albumRef.recordID.recordName, "album-hash")
        XCTAssertEqual(albumRef.action, .deleteSelf)
        XCTAssertEqual(saved.parent?.recordID, albumRef.recordID)

        XCTAssertEqual(mock.lastSavePolicy?.rawValue,
                       CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged.rawValue)
    }

    /// Preview generation can fail, leaving nothing on disk to copy. The record
    /// still has to carry a thumbnail rather than lose it to the failed snapshot.
    func testUploadFallsBackToTheLivePreviewWhenItCannotBeSnapshotted() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        let missingThumb = URL(fileURLWithPath: "/tmp/enc-\(UUID()).thumb")

        _ = try await store.upload(makeUpload(thumbURL: missingThumb), progress: { _ in })

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        let thumb = try XCTUnwrap(saved[CloudKitSchema.EncMedia.encThumbnail] as? CKAsset)
        XCTAssertEqual(thumb.fileURL, missingThumb)
    }

    /// A Live Photo is two blobs under one `mediaID`, so the record name — not the
    /// media id — is what keeps them apart. Uploading the second component must add
    /// a record, never overwrite the first.
    func testLivePhotoComponentsUploadAsTwoRecordsUnderOneMediaID() async throws {
        let mock = MockCloudKitDatabase()
        mock.rejectsSavesOfOccupiedRecordNames = true
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let photo = makeUpload(mediaID: "live-1", mediaType: .photo, recordName: "live-1")
        let video = makeUpload(mediaID: "live-1", mediaType: .video, recordName: "live-1.video")
        let photoRef = try await store.upload(photo, progress: { _ in })
        let videoRef = try await store.upload(video, progress: { _ in })

        XCTAssertEqual(photoRef.recordName, "live-1")
        XCTAssertEqual(videoRef.recordName, "live-1.video")
        XCTAssertEqual(mock.storedRecordIDs.count, 2, "Both components must survive on the server")

        let saved = mock.savedRecordBatches.compactMap { $0.first }
        XCTAssertEqual(saved.map { $0[CloudKitSchema.EncMedia.mediaID] as? String }, ["live-1", "live-1"])
        XCTAssertEqual(saved.map { $0[CloudKitSchema.EncMedia.mediaType] as? Int64 },
                       [Int64(MediaType.photo.rawValue), Int64(MediaType.video.rawValue)])
    }

    /// The store hands the caller whatever fractions the adapter reports, in order
    /// and unaltered — it clamps nothing, reorders nothing, and synthesises no
    /// terminal value, so a stalled or backwards upload is visible to the caller.
    func testUploadForwardsAdapterProgressUnchanged() async throws {
        let mock = MockCloudKitDatabase()
        mock.saveProgressValues = [0.4, 0.1, 0.9]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let box = Box()
        _ = try await store.upload(makeUpload(), progress: { box.values.append($0) })

        XCTAssertEqual(box.values, [0.4, 0.1, 0.9])
    }

    // MARK: - The iCloud -> local -> iCloud round trip

    /// Moving an album out of iCloud DELETES its media records, so moving it back
    /// re-uploads a record name the server no longer holds — an ordinary insert.
    func testUploadAfterAMoveOutIsAPlainInsertWithNoConflictHandling() async throws {
        let mock = MockCloudKitDatabase()
        mock.rejectsSavesOfOccupiedRecordNames = true
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.upload(makeUpload(), progress: { _ in })
        do {
            _ = try await store.upload(makeUpload(), progress: { _ in })
            XCTFail("Re-inserting an occupied record name must not succeed")
        } catch let error as CloudKitMediaStoreError {
            guard case .conflict = error else { return XCTFail("Wrong error: \(error)") }
        }

        try await store.delete(recordName: "media-1")
        XCTAssertTrue(mock.storedRecordIDs.isEmpty, "The move out must remove the record, not tombstone it")

        let fetchesBefore = mock.fetchCount
        _ = try await store.upload(makeUpload(), progress: { _ in })

        XCTAssertEqual(mock.fetchCount, fetchesBefore,
                       "A freed record name needs no fetch-then-revive round trip")
        let saved = try XCTUnwrap(mock.savedRecordBatches.last?.first)
        XCTAssertEqual(saved.recordID.recordName, "media-1")
        XCTAssertNotNil(saved[CloudKitSchema.EncMedia.encBlob] as? CKAsset,
                        "The re-uploaded record must carry the ciphertext")
    }

    /// The revive costs an extra round trip, so it must stay on the conflict path.
    /// Paying it per item on an ordinary migration would add a fetch to every one of
    /// a several-hundred-item album for nothing.
    func testUploadIssuesNoExtraFetchWhenTheSaveSucceeds() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.upload(makeUpload(), progress: { _ in })

        XCTAssertEqual(mock.saveCount, 1)
        XCTAssertEqual(mock.fetchCount, 0, "The happy path must not fetch before saving")
    }

    func testInjectedUploadFailureFailsOnlyTheUploadAfterTheCountAndOnlyOnce() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        CloudKitStoreTestHooks.failUpload(after: 1)
        defer { CloudKitStoreTestHooks.failUpload(after: nil) }

        _ = try await store.upload(makeUpload(mediaID: "first"), progress: { _ in })
        do {
            _ = try await store.upload(makeUpload(mediaID: "second"), progress: { _ in })
            XCTFail("The upload after the first must fail")
        } catch CloudKitMediaStoreError.quotaExceeded {
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        _ = try await store.upload(makeUpload(mediaID: "second"), progress: { _ in })

        XCTAssertEqual(mock.saveCount, 2, "The injected failure must not reach the server")
    }

    func testUploadsGoThroughWithNoFailureArmed() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        for index in 0..<3 {
            _ = try await store.upload(makeUpload(mediaID: "media-\(index)"), progress: { _ in })
        }

        XCTAssertEqual(mock.saveCount, 3)
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

    // MARK: - Chunked blob geometry survives the fetch

    /// The whole read side of chunked video hangs off three fields, and CloudKit
    /// only returns fields the caller named. Omitting them from `metadataKeys` made
    /// every chunked video read back as monolithic — so playback looked for an
    /// `encBlob` such a record never carries and failed with "Record or asset not
    /// found", and a delete could not say how many chunks to reclaim.
    func testFetchRecordMetadataReturnsChunkGeometry() async throws {
        let mock = MockCloudKitDatabase()
        let recordID = CloudKitTestFactory.recordID("vid#1")
        mock.stubbedFetchRecords = [recordID: CloudKitTestFactory.chunkedEncMediaRecord(recordName: "vid#1",
                                                                                       albumID: "a1",
                                                                                       chunkCount: 21,
                                                                                       plaintextLength: 85_000_000)]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let fetched = try await store.fetchRecordMetadata(recordName: "vid#1")
        let meta = try XCTUnwrap(fetched)
        XCTAssertEqual(meta.chunkCount, 21,
                       "a chunked record that reads back as chunkCount 0 is treated as monolithic, "
                       + "and its payload — which lives in the blob zone — becomes unreachable")
        XCTAssertEqual(meta.plaintextLength, 85_000_000)
        XCTAssertNotNil(meta.encHeader,
                        "without the header there is no geometry to stream or reassemble from")
    }

    /// The same three fields have to survive the per-album fetch, which is what
    /// populates the index a cold launch reads.
    func testFetchMetadataReturnsChunkGeometry() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [CloudKitTestFactory.chunkedEncMediaRecord(recordName: "vid#1", albumID: "a1")]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let meta = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(meta.first?.chunkCount, 3)
        XCTAssertNotNil(meta.first?.encHeader)
    }

    /// Companion to `testEveryDesiredKeysListRequestsTheKeyFingerprint`: every list
    /// that names fields must name these three, including the change feed — a delta
    /// sync that reads `chunkCount` as 0 does not merely fail to learn the geometry,
    /// it erases the geometry the coordinator already holds.
    func testEveryDesiredKeysListRequestsTheChunkFields() {
        for key in [CloudKitSchema.EncMedia.chunkCount,
                    CloudKitSchema.EncMedia.plaintextLength,
                    CloudKitSchema.EncMedia.encHeader] {
            XCTAssertTrue(CloudKitMediaStore.metadataKeys.contains(key),
                          "the metadata fetch drops \(key), so every chunked video it returns claims to be monolithic")
            XCTAssertTrue(CloudKitMediaStore.changeFeedKeys.contains(key),
                          "the zone change feed drops \(key)")
        }
    }

    /// The lazy-blob guarantee, restated for the list that just grew: the header is
    /// framing and belongs here, the payload asset never does.
    func testChunkFieldsDoNotDragTheBlobAssetAlong() {
        XCTAssertFalse(CloudKitMediaStore.metadataKeys.contains(CloudKitSchema.EncMedia.encBlob))
        XCTAssertFalse(CloudKitMediaStore.changeFeedKeys.contains(CloudKitSchema.EncMedia.encBlob))
        XCTAssertFalse(CloudKitMediaStore.metadataKeys.contains(CloudKitSchema.EncMedia.encThumbnail))
    }

    // MARK: - Key fingerprint

    func testUploadSetsKeyFingerprintOnRecord() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.upload(makeUpload(keyFingerprint: keyA.keychainLabel), progress: { _ in })

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.keyFingerprint] as? String, keyA.keychainLabel)
        XCTAssertNotEqual(keyA.keychainLabel, keyB.keychainLabel,
                          "The fixture keys must have distinct fingerprints for this to mean anything")
    }


    /// A record written before the field existed still decodes to full metadata.
    func testRecordWithoutFingerprintFieldStillLoads() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [CloudKitTestFactory.encMediaRecord(recordName: "legacy", albumID: "a1")]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let meta = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(meta.map { $0.recordName }, ["legacy"])
        XCTAssertEqual(meta.first?.sizeBytes, 1234)
    }

    func testFetchFingerprintCensusCountsPerKey() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "m2", albumID: "a1", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "m3", albumID: "a2", keyFingerprint: keyB.keychainLabel)
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 3,
                                        fingerprints: [keyA.keychainLabel: 2, keyB.keychainLabel: 1]))
    }

    /// Unknown does not become a bucket of its own. `mediaCount: 3` pins "records
    /// exist but none of them names a key", which the fingerprint map alone cannot
    /// express.
    func testFetchFingerprintCensusCountsRecordsThatNameNoKey() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "live", albumID: "a1", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encMediaRecord(recordName: "legacy", albumID: "a1"),
            CloudKitTestFactory.encMediaRecord(recordName: "blank", albumID: "a1", keyFingerprint: "")
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 3, fingerprints: [keyA.keychainLabel: 1]))
    }

    /// Counting downloads no media and issues no save, so no `CKAsset` is rewritten.
    func testFetchFingerprintCensusFetchesNoAssets() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1", keyFingerprint: keyA.keychainLabel)
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.fetchFingerprintCensus()

        let desired = try XCTUnwrap(mock.lastQueryDesiredKeys)
        XCTAssertFalse(desired.contains(CloudKitSchema.EncMedia.encBlob))
        XCTAssertFalse(desired.contains(CloudKitSchema.EncMedia.encThumbnail))
        XCTAssertEqual(mock.fetchCount, 0, "Counting must not fetch records by ID")
        XCTAssertEqual(mock.saveCount, 0, "Counting must never rewrite a record, and so never an asset")
    }

    /// A container whose schema cannot answer the query yet (record type or
    /// `createdAt` index not deployed) degrades to `.indexUnavailable` rather than
    /// throwing.
    func testFetchFingerprintCensusDegradesWhenSchemaNotReady() async throws {
        for code in [CKError.Code.invalidArguments, .unknownItem] {
            let mock = MockCloudKitDatabase()
            mock.queryError = CKErrorFactory.error(code)
            let store = makeStore(adapter: mock, defaults: freshDefaults("degrade-\(code.rawValue)"))

            let census = try await store.fetchFingerprintCensus()
            XCTAssertEqual(census, .indexUnavailable,
                           "\(code) must degrade to 'I could not tell', not 'no data' and not a throw")
        }
    }

    /// A real I/O failure still surfaces rather than degrading.
    func testFetchFingerprintCensusStillThrowsOnRealFailure() async {
        let mock = MockCloudKitDatabase()
        mock.queryError = CKErrorFactory.error(.quotaExceeded)
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        do {
            _ = try await store.fetchFingerprintCensus()
            XCTFail("Expected the quota error to propagate")
        } catch let error as CloudKitMediaStoreError {
            guard case .quotaExceeded = error else { return XCTFail("Wrong case: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSaveAlbumSetsKeyFingerprint() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.saveAlbum(CloudKitAlbumUpload(albumID: "album-hash",
                                                      encName: "cipher",
                                                      createdAt: Date(timeIntervalSince1970: 100),
                                                      isHidden: false,
                                                      keyFingerprint: keyA.keychainLabel))

        let saved = try XCTUnwrap(mock.savedRecordBatches.first?.first)
        XCTAssertEqual(saved.recordType, CloudKitSchema.EncAlbum.recordType)
        XCTAssertEqual(saved[CloudKitSchema.EncAlbum.keyFingerprint] as? String, keyA.keychainLabel)
    }


    /// The album record is the one place the fingerprint survives when an album has
    /// no live media, so `fetchAllAlbums` must read it back — and a pre-field record
    /// must come back `nil` ("unknown"), never "".
    func testFetchAllAlbumsReadsKeyFingerprintBack() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [
            CloudKitTestFactory.encAlbumRecord(albumID: "stamped", keyFingerprint: keyA.keychainLabel),
            CloudKitTestFactory.encAlbumRecord(albumID: "legacy")
        ]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.first { $0.albumID == "stamped" }?.keyFingerprint, keyA.keychainLabel)
        let legacy = try XCTUnwrap(albums.first { $0.albumID == "legacy" })
        XCTAssertNil(legacy.keyFingerprint)
    }

    func testFetchAllAlbumsReportsNoAlbumsWhenTheZoneIsGone() async throws {
        let zoneKey = "cloudkit_zone_created_v1_" + CloudKitSchema.containerID
        let defaults = freshDefaults()
        defaults.set(true, forKey: zoneKey)
        let mock = MockCloudKitDatabase()
        mock.queryError = CKErrorFactory.error(.zoneNotFound)
        let store = makeStore(adapter: mock, defaults: defaults)

        let albums = try await store.fetchAllAlbums()

        XCTAssertTrue(albums.isEmpty, "A missing zone is an empty enumeration, not a failure")
        XCTAssertFalse(defaults.bool(forKey: zoneKey),
                       "The stale zone-created flag must still be cleared, so the next write recreates the zone")
    }

    func testFetchAllAlbumsStillThrowsWhenTheQueryMerelyFailed() async throws {
        let mock = MockCloudKitDatabase()
        mock.queryError = CKErrorFactory.error(.requestRateLimited)
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        do {
            _ = try await store.fetchAllAlbums()
            XCTFail("A throttled query must not degrade to an empty album list")
        } catch let error as CloudKitMediaStoreError {
            guard case .retry = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    // MARK: - fetchAlbum (by id)

    func testFetchAlbumReadsTheRecordByIDNotThroughTheQuery() async throws {
        let mock = MockCloudKitDatabase()
        let record = CloudKitTestFactory.encAlbumRecord(albumID: "fresh", keyFingerprint: keyA.keychainLabel)
        mock.stubbedFetchRecords = [record.recordID: record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let album = try await store.fetchAlbum(albumID: "fresh")

        XCTAssertEqual(album?.albumID, "fresh")
        XCTAssertEqual(album?.keyFingerprint, keyA.keychainLabel)
        XCTAssertEqual(mock.fetchCount, 1, "a fetch by id is the strongly consistent read")
        XCTAssertNil(mock.lastQueryDesiredKeys, "the eventually consistent query must not be used")
    }

    func testFetchAlbumReturnsNilWhenTheServerHasNoSuchRecord() async throws {
        let store = makeStore(adapter: MockCloudKitDatabase(), defaults: freshDefaults())
        let album = try await store.fetchAlbum(albumID: "gone")
        XCTAssertNil(album)
    }

    func testFetchAlbumReadsUnknownItemAsNotFound() async throws {
        let mock = MockCloudKitDatabase()
        mock.fetchError = CKErrorFactory.error(.unknownItem)
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        let album = try await store.fetchAlbum(albumID: "gone")
        XCTAssertNil(album)
    }

    func testFetchAlbumReadsAPartialFailureOfUnknownItemAsNotFound() async throws {
        let mock = MockCloudKitDatabase()
        let recordID = CKRecord.ID(recordName: "gone", zoneID: CloudKitTestFactory.zoneID)
        mock.fetchError = CKErrorFactory.error(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [recordID: CKErrorFactory.error(.unknownItem)]
        ])
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        let album = try await store.fetchAlbum(albumID: "gone")
        XCTAssertNil(album)
    }

    func testFetchAlbumThrowsWhenTheServerCouldNotAnswer() async {
        for code in [CKError.Code.requestRateLimited, .networkUnavailable, .zoneNotFound] {
            let mock = MockCloudKitDatabase()
            mock.fetchError = CKErrorFactory.error(code)
            let store = makeStore(adapter: mock, defaults: freshDefaults("\(#function)-\(code.rawValue)"))
            do {
                _ = try await store.fetchAlbum(albumID: "album")
                XCTFail("\(code) must not read as \"no such record\"")
            } catch {}
        }
    }

    func testFetchAlbumThrowsWhenTheRecordExistsButCannotBeRead() async {
        let mock = MockCloudKitDatabase()
        let record = CKRecord(recordType: CloudKitSchema.EncAlbum.recordType,
                              recordID: CKRecord.ID(recordName: "bare", zoneID: CloudKitTestFactory.zoneID))
        mock.stubbedFetchRecords = [record.recordID: record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())
        do {
            _ = try await store.fetchAlbum(albumID: "bare")
            XCTFail("a record that exists must never read as gone")
        } catch {}
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

        try FileManager.default.removeItem(at: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), payload)

        XCTAssertEqual(mock.lastFetchDesiredKeys, [CloudKitSchema.EncMedia.encBlob])
    }

    /// Asset transfers run in the top QoS band — CloudKit moves them markedly
    /// faster there, and something on screen is always waiting on one.
    func testAssetFetchesRunAtUserInteractiveQoS() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ck-temp-\(UUID()).bin")
        try Data("ciphertext".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let record = CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: temp)
        record[CloudKitSchema.EncMedia.encThumbnail] = CKAsset(fileURL: temp)

        let mock = MockCloudKitDatabase()
        mock.stubbedFetchRecords = [CloudKitTestFactory.recordID("m1"): record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ck-dest-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        try await store.fetchBlob(recordName: "m1", to: dest, progress: { _ in })
        XCTAssertEqual(mock.lastFetchQualityOfService, .userInteractive)

        try await store.fetchThumbnail(recordName: "m1", to: dest)
        XCTAssertEqual(mock.lastFetchQualityOfService, .userInteractive)
    }

    /// The elevated band is reserved for asset transfers: bookkeeping fetches stay
    /// at the default so they do not compete with a download the user is watching.
    func testNonAssetFetchesStayAtDefaultQoS() async throws {
        let record = CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")
        let mock = MockCloudKitDatabase()
        mock.stubbedFetchRecords = [CloudKitTestFactory.recordID("m1"): record]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.fetchRecordMetadata(recordName: "m1")
        XCTAssertEqual(mock.lastFetchQualityOfService, .userInitiated)
    }

    /// The eager-thumbnail query is an asset transfer too, so it gets the same
    /// treatment — but only when the thumbnail is actually requested.
    func testMetadataQueryRaisesQoSOnlyForEagerThumbnails() async throws {
        let mock = MockCloudKitDatabase()
        mock.stubbedQueryRecords = [CloudKitTestFactory.encMediaRecord(recordName: "m1", albumID: "a1")]
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        _ = try await store.fetchMetadata(albumID: "a1", includeThumbnail: false)
        XCTAssertEqual(mock.lastQueryQualityOfService, .userInitiated)

        _ = try await store.fetchMetadata(albumID: "a1", includeThumbnail: true)
        XCTAssertEqual(mock.lastQueryQualityOfService, .userInteractive)
    }

    // MARK: - Delete

    func testDeleteIsAtomicSingleOp() async throws {
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: freshDefaults())

        try await store.delete(recordName: "m1")

        XCTAssertEqual(mock.deleteCount, 1)
        XCTAssertEqual(mock.fetchCount, 0, "No separate blob op — delete removes the record and both assets atomically")
        XCTAssertEqual(mock.deletedRecordIDBatches.first?.first, CloudKitTestFactory.recordID("m1"))
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
        let mapped = mapCKError(CKErrorFactory.error(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [
                CloudKitTestFactory.recordID("m1"): CKErrorFactory.error(.serverRecordChanged),
                CloudKitTestFactory.recordID("m3"): CKErrorFactory.error(.quotaExceeded)
            ] as [AnyHashable: Error]]
        ))
        guard case .partial(let failed) = mapped else { return XCTFail("Expected partial, got \(mapped)") }
        XCTAssertEqual(Set(failed.keys), ["m1", "m3"], "Exactly the failed records are reported")
        XCTAssertEqual((failed["m1"] as? NSError)?.code, CKError.Code.serverRecordChanged.rawValue)
        XCTAssertEqual((failed["m3"] as? NSError)?.code, CKError.Code.quotaExceeded.rawValue)
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

        try await store.registerZoneSubscription()
        XCTAssertEqual(mock.savedSubscriptions.count, 1)
    }

    func testRegisterZoneSubscriptionNoOpsWhenFlagAlreadySet() async throws {
        let defaults = freshDefaults()
        let subKey = "cloudkit_zone_subscription_v1_" + CloudKitSchema.containerID
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: defaults)

        try await store.registerZoneSubscription()
        XCTAssertEqual(mock.savedSubscriptions.count, 1)
        XCTAssertTrue(defaults.bool(forKey: subKey),
                      "a successful registration must persist the flag it later reads")

        try await store.registerZoneSubscription()

        XCTAssertEqual(mock.savedSubscriptions.count, 1,
                       "an already-registered subscription must not be saved again")
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
            deleted: [DeletedRecord(recordName: "m2", recordType: CloudKitSchema.EncMedia.recordType)],
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

    // MARK: - Interrupted uploads / legacy long-lived state

    /// The crash was armed by *persisted* long-lived operation IDs that a later store
    /// construction handed back to CloudKit. Constructing a store must clear the map
    /// an older build left behind, so there is nothing left to hand back.
    func testConstructingAStoreClearsTheLegacyLongLivedOperationMap() {
        let defaults = freshDefaults()
        defaults.set(["m1": "3090886DAE392CF7", "m2": "opB"], forKey: longLivedMapKey)

        _ = makeStore(adapter: MockCloudKitDatabase(), defaults: defaults)

        XCTAssertNil(defaults.object(forKey: longLivedMapKey),
                     "A stale long-lived operation map must not survive store construction")
    }

    /// Store construction used to kick off a CloudKit round-trip (fetch all
    /// long-lived operation IDs, then re-enqueue each). It must now be inert: the
    /// app builds one store per album namespace on launch, and every one of those
    /// re-enqueues was a chance to raise the uncatchable `CKException`.
    func testConstructingManyStoresIssuesNoCloudKitWork() async {
        let defaults = freshDefaults()
        defaults.set(["m1": "opA"], forKey: longLivedMapKey)
        let mock = MockCloudKitDatabase()

        for _ in 0..<5 {
            _ = makeStore(adapter: mock, defaults: defaults)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mock.saveCount, 0)
        XCTAssertEqual(mock.fetchCount, 0)
        XCTAssertEqual(mock.deleteCount, 0)
        XCTAssertNil(defaults.object(forKey: longLivedMapKey))
    }

    /// An upload killed part-way (here: the save fails, standing in for the process
    /// dying between issuing and completing it) must leave nothing behind that makes
    /// the next attempt at the same record misbehave — the retry is an ordinary save.
    func testInterruptedUploadLeavesNoStateThatBreaksTheNextSave() async throws {
        let defaults = freshDefaults()
        defaults.set(["media-1": "3090886DAE392CF7"], forKey: longLivedMapKey)
        let mock = MockCloudKitDatabase()
        let store = makeStore(adapter: mock, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: longLivedMapKey),
                     "Constructing the store must drop the map before anything can hand it back")

        mock.saveError = CKErrorFactory.error(.networkFailure)
        do {
            _ = try await store.upload(makeUpload(), progress: { _ in })
            XCTFail("Expected the interrupted upload to fail")
        } catch {
            // expected
        }

        mock.saveError = nil
        let ref = try await store.upload(makeUpload(), progress: { _ in })

        XCTAssertEqual(ref.recordName, "media-1")
        XCTAssertEqual(mock.saveCount, 2, "The retry is a fresh, ordinary save")
        XCTAssertNil(defaults.object(forKey: longLivedMapKey),
                     "An interrupted upload must not record a long-lived operation")
    }

    /// The full repro shape: an upload is interrupted, the app is "relaunched"
    /// (fresh stores over the same app-group defaults), and the migration resumes.
    /// Nothing is re-enqueued and the resumed upload succeeds.
    func testRelaunchAfterAnInterruptedUploadResumesWithoutReattachingAnything() async throws {
        let defaults = freshDefaults()
        let firstMock = MockCloudKitDatabase()
        let firstStore = makeStore(adapter: firstMock, defaults: defaults)
        firstMock.saveError = CKErrorFactory.error(.networkFailure)
        do {
            _ = try await firstStore.upload(makeUpload(), progress: { _ in })
            XCTFail("Expected the upload to be interrupted")
        } catch {
            // expected
        }
        defaults.set(["media-1": "3090886DAE392CF7"], forKey: longLivedMapKey)

        let secondMock = MockCloudKitDatabase()
        var stores: [CloudKitMediaStore] = []
        for _ in 0..<3 { stores.append(makeStore(adapter: secondMock, defaults: defaults)) }
        XCTAssertEqual(secondMock.saveCount, 0, "No store construction may issue a CloudKit operation")
        XCTAssertNil(defaults.object(forKey: longLivedMapKey),
                     "The relaunch must drop the recorded operation rather than re-attach to it")

        let ref = try await XCTUnwrap(stores.last).upload(makeUpload(), progress: { _ in })

        XCTAssertEqual(ref.recordName, "media-1")
        XCTAssertEqual(secondMock.saveCount, 1)
    }

    // MARK: - reassignAlbum

    /// Seed 401 records, call reassign, verify the mock adapter got 2 fetch + 2 save
    /// calls (the 400-record CloudKit batch limit is respected).
    func testReassignAlbumBatchesAt400Records() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter, defaults: freshDefaults())

        // Seed 401 records into the mock adapter.
        var names: [String] = []
        for i in 0..<401 {
            let name = "rec-\(i)"
            names.append(name)
            let record = CloudKitTestFactory.encMediaRecord(recordName: name, albumID: "old-album")
            adapter.stubbedFetchRecords[record.recordID] = record
        }

        let notFound = try await store.reassignAlbum(recordNames: names, toAlbumID: "new-album")
        XCTAssertTrue(notFound.isEmpty)
        XCTAssertEqual(adapter.fetchCount, 2, "401 records should produce 2 fetch batches (400 + 1)")
        XCTAssertEqual(adapter.saveCount, 2, "401 records should produce 2 save batches (400 + 1)")
    }

    /// Reassign one record and verify the saved CKRecord has albumID, albumRef and
    /// parent set correctly, and NO asset keys (encBlob, encThumbnail) were touched.
    func testReassignAlbumSetsAlbumIDRefAndParentOnly() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter, defaults: freshDefaults())

        let record = CloudKitTestFactory.encMediaRecord(recordName: "media-A", albumID: "old-album")
        adapter.stubbedFetchRecords[record.recordID] = record

        _ = try await store.reassignAlbum(recordNames: ["media-A"], toAlbumID: "new-album")

        let saved = try XCTUnwrap(adapter.savedRecordBatches.last?.first)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.albumID] as? String, "new-album")

        let albumRef = try XCTUnwrap(saved[CloudKitSchema.EncMedia.albumRef] as? CKRecord.Reference)
        XCTAssertEqual(albumRef.recordID.recordName, "new-album")
        XCTAssertEqual(albumRef.action, .deleteSelf)

        let parent = try XCTUnwrap(saved.parent)
        XCTAssertEqual(parent.recordID.recordName, "new-album")

        // Asset fields must NOT appear — the fetch requested only albumID.
        XCTAssertNil(saved[CloudKitSchema.EncMedia.encBlob])
        XCTAssertNil(saved[CloudKitSchema.EncMedia.encThumbnail])

        XCTAssertEqual(adapter.lastSavePolicy?.rawValue,
                       CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged.rawValue)
        XCTAssertEqual(adapter.lastFetchDesiredKeys, [CloudKitSchema.EncMedia.albumID])
    }

    /// Call reassign with a name that does not exist in the adapter; verify it is
    /// returned in the not-found list.
    func testReassignAlbumReturnsMissingRecordNames() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter, defaults: freshDefaults())

        let notFound = try await store.reassignAlbum(recordNames: ["ghost-1", "ghost-2"],
                                                      toAlbumID: "new-album")
        XCTAssertEqual(Set(notFound), Set(["ghost-1", "ghost-2"]))
        // Nothing to save when every record is missing.
        XCTAssertEqual(adapter.saveCount, 0)
    }

    /// Inject a partial failure from the adapter and verify it is mapped via
    /// mapAndRecord (i.e. the error comes back as a CloudKitMediaStoreError).
    func testReassignAlbumMapsPartialFailure() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter, defaults: freshDefaults())

        let record = CloudKitTestFactory.encMediaRecord(recordName: "media-A", albumID: "old-album")
        adapter.stubbedFetchRecords[record.recordID] = record
        adapter.saveError = CKErrorFactory.error(.zoneBusy)

        do {
            _ = try await store.reassignAlbum(recordNames: ["media-A"], toAlbumID: "new-album")
            XCTFail("Expected an error from reassignAlbum")
        } catch let error as CloudKitMediaStoreError {
            // zoneBusy is mapped to .retry — verify the raw CKError was translated
            if case .retry = error {
                // correct
            } else {
                XCTFail("Expected .retry, got \(error)")
            }
        }
    }
}
