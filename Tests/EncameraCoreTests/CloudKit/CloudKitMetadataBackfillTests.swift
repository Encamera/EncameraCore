//
//  CloudKitMetadataBackfillTests.swift
//  EncameraCoreTests
//
//  Filling a missing `encMetadata` field on an existing record: the store's
//  attach, the byte-exact read of a file's metadata, and sealing those bytes.
//

import CloudKit
import Sodium
import XCTest
@testable import EncameraCore

final class CloudKitMetadataBackfillTests: XCTestCase {

    private let key: [UInt8] = Array(repeating: 0x42, count: 32)
    private let otherKey: [UInt8] = Array(repeating: 0x24, count: 32)
    private let recordName = "media-1#0"

    // MARK: - Fixtures

    private func knownMetadata() -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.schemaVersion = 1
        metadata.captureDate = Date(timeIntervalSince1970: 1_500_000_000)
        metadata.encryptionDate = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.originalFilename = "IMG_0001.HEIC"
        return metadata
    }

    /// Metadata JSON as a newer build might write it: the known fields plus a key
    /// this build's `EncryptedFileMetadata` does not declare.
    private func metadataJSONWithUnknownKey() throws -> Data {
        let known = try EncryptedMetadataHandler.encodeMetadata(knownMetadata())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: known) as? [String: Any])
        XCTAssertNil(object["futureField"], "the fixture key must be unknown to this build")
        object["futureField"] = ["nested": "kept", "count": 3]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-backfill-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// An ENC2 file whose metadata section encrypts `json` exactly, as
    /// `EncryptedMetadataHandler.buildV2Header` lays it out, followed by content
    /// bytes the metadata read never touches.
    private func writeENC2File(metadataJSON json: Data, keyBytes: [UInt8]) throws -> URL {
        let push = try XCTUnwrap(Sodium().secretStream.xchacha20poly1305.initPush(secretKey: keyBytes))
        let streamHeader = push.header()
        let cipherText = try XCTUnwrap(push.push(message: [UInt8](json), tag: .FINAL))
        var file = Data(EncryptedFileFormat.magic)
        var version = EncryptedFileFormat.version
        withUnsafeBytes(of: &version) { file.append(contentsOf: $0) }
        var flags: UInt16 = 0
        withUnsafeBytes(of: &flags) { file.append(contentsOf: $0) }
        var length = UInt32(streamHeader.count + cipherText.count)
        withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
        file.append(contentsOf: streamHeader)
        file.append(contentsOf: cipherText)
        file.append(Data("content that is never decrypted".utf8))
        let url = try makeDirectory().appendingPathComponent("photo.enc2")
        try file.write(to: url)
        return url
    }

    /// An ENC3 file whose header seals `json` exactly, or carries no metadata
    /// section when `json` is nil.
    private func writeENC3File(metadataJSON json: Data?, keyBytes: [UInt8]) throws -> URL {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("plain.mov")
        try Data(repeating: 0xAB, count: 4096).write(to: source)
        let destination = directory.appendingPathComponent("video.enc3")
        try SeekableEncryptedWriter(keyBytes: keyBytes, chunkSize: 1024)
            .encrypt(source: source, destination: destination, metadata: json)
        return destination
    }

    /// The plaintext sealed in `sealed`, opened byte for byte rather than decoded.
    private func openSealedBytes(_ sealed: Data, recordName: String) -> Data? {
        Sodium().aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: [UInt8](sealed),
            secretKey: key,
            additionalData: CloudKitRecordMetadataHandler.additionalData(recordName: recordName)
        ).map { Data($0) }
    }

    // MARK: - Reading the file's metadata bytes

    func testENC2MetadataBytesAreExactlyTheEncryptedJSONIncludingUnknownKeys() async throws {
        let json = try metadataJSONWithUnknownKey()
        let file = try writeENC2File(metadataJSON: json, keyBytes: key)

        let bytes = try await EncryptedMetadataHandler().readMetadataBytes(from: file, keyBytes: key)

        XCTAssertEqual(bytes, json)
    }

    func testENC3MetadataBytesAreExactlyTheEncryptedJSONIncludingUnknownKeys() async throws {
        let json = try metadataJSONWithUnknownKey()
        let file = try writeENC3File(metadataJSON: json, keyBytes: key)

        let bytes = try await EncryptedMetadataHandler().readMetadataBytes(from: file, keyBytes: key)

        XCTAssertEqual(bytes, json)
    }

    func testMetadataBytesAreNilForAV1FileAndAnENC3FileWithoutMetadata() async throws {
        let v1 = try makeDirectory().appendingPathComponent("legacy.enc")
        try Data("V1-ciphertext-without-magic".utf8).write(to: v1)
        let bare = try writeENC3File(metadataJSON: nil, keyBytes: key)
        let handler = EncryptedMetadataHandler()

        let v1Bytes = try await handler.readMetadataBytes(from: v1, keyBytes: key)
        let bareBytes = try await handler.readMetadataBytes(from: bare, keyBytes: key)

        XCTAssertNil(v1Bytes)
        XCTAssertNil(bareBytes)
    }

    // MARK: - readMetadata decodes those bytes, as before

    func testReadMetadataDecodesENC2AndENC3FilesToTheirMetadata() async throws {
        let metadata = knownMetadata()
        let handler = EncryptedMetadataHandler()
        let enc2 = try makeDirectory().appendingPathComponent("photo.enc2")
        try handler.buildV2Header(metadata: metadata, keyBytes: key).write(to: enc2)
        let enc3 = try writeENC3File(metadataJSON: try EncryptedMetadataHandler.encodeMetadata(metadata),
                                     keyBytes: key)

        let fromENC2 = try await handler.readMetadata(from: enc2, keyBytes: key)
        let fromENC3 = try await handler.readMetadata(from: enc3, keyBytes: key)

        XCTAssertEqual(fromENC2, metadata)
        XCTAssertEqual(fromENC3, metadata)
    }

    func testReadMetadataDecodesTheKnownFieldsOfJSONWithAnUnknownKey() async throws {
        let json = try metadataJSONWithUnknownKey()
        let handler = EncryptedMetadataHandler()
        let enc2 = try writeENC2File(metadataJSON: json, keyBytes: key)
        let enc3 = try writeENC3File(metadataJSON: json, keyBytes: key)

        let fromENC2 = try await handler.readMetadata(from: enc2, keyBytes: key)
        let fromENC3 = try await handler.readMetadata(from: enc3, keyBytes: key)

        XCTAssertEqual(fromENC2, knownMetadata())
        XCTAssertEqual(fromENC3, knownMetadata())
    }

    func testReadMetadataIsNilForAV1FileAndAnENC3FileWithoutMetadata() async throws {
        let v1 = try makeDirectory().appendingPathComponent("legacy.enc")
        try Data("V1-ciphertext-without-magic".utf8).write(to: v1)
        let bare = try writeENC3File(metadataJSON: nil, keyBytes: key)
        let handler = EncryptedMetadataHandler()

        let fromV1 = try await handler.readMetadata(from: v1, keyBytes: key)
        let fromBare = try await handler.readMetadata(from: bare, keyBytes: key)

        XCTAssertNil(fromV1)
        XCTAssertNil(fromBare)
    }

    func testReadMetadataUnderTheWrongKeyThrowsAsBefore() async throws {
        let json = try EncryptedMetadataHandler.encodeMetadata(knownMetadata())
        let handler = EncryptedMetadataHandler()
        let enc2 = try writeENC2File(metadataJSON: json, keyBytes: key)
        let enc3 = try writeENC3File(metadataJSON: json, keyBytes: key)

        do {
            _ = try await handler.readMetadata(from: enc2, keyBytes: otherKey)
            XCTFail("an ENC2 metadata section must not open under another key")
        } catch EncryptedMetadataError.decryptionFailed {
        }
        do {
            _ = try await handler.readMetadata(from: enc3, keyBytes: otherKey)
            XCTFail("an ENC3 metadata section must not open under another key")
        } catch SeekableFormatError.metadataAuthenticationFailed {
        }
    }

    func testReadMetadataOfAMissingFileThrowsFileNotFound() async throws {
        let missing = try makeDirectory().appendingPathComponent("gone.enc")

        do {
            _ = try await EncryptedMetadataHandler().readMetadata(from: missing, keyBytes: key)
            XCTFail("a missing file must throw")
        } catch EncryptedMetadataError.fileNotFound {
        }
    }

    // MARK: - Sealing bytes for the record

    func testEncryptedBytesReadBackToTheirMetadata() throws {
        let json = try EncryptedMetadataHandler.encodeMetadata(knownMetadata())

        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(bytes: json, recordName: recordName, keyBytes: key)

        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: recordName, keyBytes: key), knownMetadata())
        XCTAssertEqual(openSealedBytes(sealed, recordName: recordName), json)
    }

    func testSealedBytesKeepUnknownKeysVerbatim() throws {
        let json = try metadataJSONWithUnknownKey()

        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(bytes: json, recordName: recordName, keyBytes: key)

        XCTAssertEqual(openSealedBytes(sealed, recordName: recordName), json)
        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: recordName, keyBytes: key), knownMetadata())
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: "media-2#0", keyBytes: key),
                     "sealed bytes stay bound to their record name")
    }

    func testEncryptingTheStructEncryptsItsEncodedJSON() throws {
        let metadata = knownMetadata()

        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(metadata, recordName: recordName, keyBytes: key)

        XCTAssertEqual(openSealedBytes(sealed, recordName: recordName),
                       try EncryptedMetadataHandler.encodeMetadata(metadata))
    }

    // MARK: - attachMetadata on the real store

    private func makeStore(adapter: MockCloudKitDatabase, defaultsLabel: String = #function) -> CloudKitMediaStore {
        let defaults = makeIsolatedDefaults(defaultsLabel)
        let container = CloudKitContainer(accountStatusProvider: StubAccountStatusProvider(status: .available),
                                          zoneProvisioner: StubZoneProvisioner(),
                                          zoneLister: StubZoneLister(),
                                          subscriptionProvisioner: StubSubscriptionProvisioner(),
                                          defaults: defaults)
        return CloudKitMediaStore(container: container, adapter: adapter, defaults: defaults)
    }

    /// A server record as another device saved it, with `encBlob` and every index
    /// field, and `encMetadata` only when given.
    private func serverRecord(_ recordName: String, encMetadata: Data?) throws -> CKRecord {
        let record = CloudKitTestFactory.encMediaRecord(recordName: recordName, albumID: "album-1",
                                                        keyFingerprint: "fingerprint-a")
        let blob = try makeDirectory().appendingPathComponent("blob.enc")
        try Data("blob".utf8).write(to: blob)
        record[CloudKitSchema.EncMedia.encBlob] = CKAsset(fileURL: blob)
        if let encMetadata { record[CloudKitSchema.EncMedia.encMetadata] = encMetadata as CKRecordValue }
        return record
    }

    func testAttachMetadataSavesOnlyTheMetadataKey() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter)
        let record = try serverRecord("media-A", encMetadata: nil)
        adapter.stubbedFetchRecords[record.recordID] = record
        let sealed = Data("mine".utf8)

        let result = try await store.attachMetadata(recordName: "media-A", sealed: sealed)

        XCTAssertEqual(adapter.lastFetchDesiredKeys, [CloudKitSchema.EncMedia.encMetadata])
        XCTAssertEqual(adapter.saveCount, 1)
        let saved = try XCTUnwrap(adapter.savedRecordBatches.last?.first)
        XCTAssertEqual(saved.recordID.recordName, "media-A")
        XCTAssertEqual(Set(saved.changedKeys()), [CloudKitSchema.EncMedia.encMetadata],
                       "only encMetadata may reach the server; every other field stays as it is")
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.encMetadata] as? Data, sealed)
        XCTAssertEqual(adapter.lastSavePolicy?.rawValue,
                       CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged.rawValue)
        XCTAssertEqual(result, .attached(changeTag: saved.recordChangeTag))
    }

    func testAttachMetadataLeavesAnExistingValueAlone() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter)
        let record = try serverRecord("media-A", encMetadata: Data("theirs".utf8))
        adapter.stubbedFetchRecords[record.recordID] = record

        let result = try await store.attachMetadata(recordName: "media-A", sealed: Data("mine".utf8))

        XCTAssertEqual(result, .alreadyPresent)
        XCTAssertEqual(adapter.saveCount, 0, "an existing encMetadata is never overwritten")
        XCTAssertEqual(record[CloudKitSchema.EncMedia.encMetadata] as? Data, Data("theirs".utf8))
    }

    func testAttachMetadataReportsAMissingRecord() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter)

        let result = try await store.attachMetadata(recordName: "ghost", sealed: Data("mine".utf8))

        XCTAssertEqual(result, .recordMissing)
        XCTAssertEqual(adapter.saveCount, 0)
    }

    func testAttachMetadataConflictRefetchesOnceAndKeepsTheOtherDevicesValue() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter)
        let bare = try serverRecord("media-A", encMetadata: nil)
        let attachedElsewhere = try serverRecord("media-A", encMetadata: Data("theirs".utf8))
        adapter.stubbedFetchRecords[bare.recordID] = bare
        adapter.saveErrorSequence = [CKErrorFactory.error(.serverRecordChanged)]
        adapter.onSave = { [unowned adapter] _ in
            adapter.stubbedFetchRecords[attachedElsewhere.recordID] = attachedElsewhere
        }

        let result = try await store.attachMetadata(recordName: "media-A", sealed: Data("mine".utf8))

        XCTAssertEqual(result, .alreadyPresent)
        XCTAssertEqual(adapter.fetchCount, 2, "one fetch, then one refetch after the conflict")
        XCTAssertEqual(adapter.saveCount, 1, "the other device's metadata is kept, not overwritten")
        XCTAssertEqual(adapter.stubbedFetchRecords[bare.recordID]?[CloudKitSchema.EncMedia.encMetadata] as? Data,
                       Data("theirs".utf8))
    }

    func testAttachMetadataConflictWithoutAnotherValueSavesOnceMore() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter)
        let bare = try serverRecord("media-A", encMetadata: nil)
        adapter.stubbedFetchRecords[bare.recordID] = bare
        adapter.saveErrorSequence = [CKErrorFactory.error(.serverRecordChanged), nil]
        let sealed = Data("mine".utf8)

        let result = try await store.attachMetadata(recordName: "media-A", sealed: sealed)

        let saved = try XCTUnwrap(adapter.savedRecordBatches.last?.first)
        XCTAssertEqual(result, .attached(changeTag: saved.recordChangeTag))
        XCTAssertEqual(adapter.fetchCount, 2)
        XCTAssertEqual(adapter.saveCount, 2)
        XCTAssertEqual(saved[CloudKitSchema.EncMedia.encMetadata] as? Data, sealed)
    }

    func testAttachMetadataThrowsAfterASecondConflict() async throws {
        let adapter = MockCloudKitDatabase()
        let store = makeStore(adapter: adapter)
        let bare = try serverRecord("media-A", encMetadata: nil)
        adapter.stubbedFetchRecords[bare.recordID] = bare
        adapter.saveErrorSequence = [CKErrorFactory.error(.serverRecordChanged),
                                     CKErrorFactory.error(.serverRecordChanged)]

        do {
            _ = try await store.attachMetadata(recordName: "media-A", sealed: Data("mine".utf8))
            XCTFail("a second conflict must throw")
        } catch CloudKitMediaStoreError.conflict {
        }
        XCTAssertEqual(adapter.saveCount, 2, "the save is retried once, never more")
    }

    // MARK: - attachMetadata on the doubles

    private func uploadRecord(to store: CloudKitMediaStoring,
                              recordName: String,
                              encMetadata: Data? = nil) async throws {
        let blob = try makeDirectory().appendingPathComponent("blob.enc")
        try Data("ciphertext".utf8).write(to: blob)
        _ = try await store.upload(CloudKitMediaUpload(albumID: "album-1",
                                                       mediaID: recordName,
                                                       mediaType: .photo,
                                                       createdAt: Date(timeIntervalSince1970: 1_000),
                                                       sizeBytes: 10,
                                                       encryptedFileURL: blob,
                                                       encryptedThumbURL: nil,
                                                       recordName: recordName,
                                                       keyFingerprint: "fingerprint-a",
                                                       encMetadata: encMetadata),
                                   progress: { _ in })
    }

    func testInMemoryStoreAttachesKeepsAndReportsMissingLikeTheRealStore() async throws {
        let store = InMemoryCloudKitMediaStore()
        try await uploadRecord(to: store, recordName: "bare")
        try await uploadRecord(to: store, recordName: "carrying", encMetadata: Data("theirs".utf8))

        let attached = try await store.attachMetadata(recordName: "bare", sealed: Data("mine".utf8))
        let afterAttach = try await store.fetchRecordMetadata(recordName: "bare")
        let present = try await store.attachMetadata(recordName: "carrying", sealed: Data("mine".utf8))
        let carrying = try await store.fetchRecordMetadata(recordName: "carrying")
        let missing = try await store.attachMetadata(recordName: "ghost", sealed: Data("mine".utf8))

        XCTAssertEqual(attached, .attached(changeTag: afterAttach?.recordChangeTag))
        XCTAssertEqual(afterAttach?.descriptor.encMetadata, Data("mine".utf8))
        XCTAssertEqual(present, .alreadyPresent)
        XCTAssertEqual(carrying?.descriptor.encMetadata, Data("theirs".utf8))
        XCTAssertEqual(missing, .recordMissing)
    }

    func testInMemoryStoreKeepsTheFirstOfTwoAttaches() async throws {
        let store = InMemoryCloudKitMediaStore()
        try await uploadRecord(to: store, recordName: "bare")

        let first = try await store.attachMetadata(recordName: "bare", sealed: Data("first".utf8))
        let tagAfterFirst = try await store.fetchRecordMetadata(recordName: "bare")?.recordChangeTag
        let second = try await store.attachMetadata(recordName: "bare", sealed: Data("second".utf8))
        let after = try await store.fetchRecordMetadata(recordName: "bare")

        XCTAssertEqual(first, .attached(changeTag: tagAfterFirst))
        XCTAssertEqual(second, .alreadyPresent)
        XCTAssertEqual(after?.descriptor.encMetadata, Data("first".utf8))
        XCTAssertEqual(after?.recordChangeTag, tagAfterFirst, "the second attach saves nothing")
    }

    func testMockStoreAttachesKeepsAndReportsMissingLikeTheRealStore() async throws {
        let store = MockCloudKitMediaStore()
        try await uploadRecord(to: store, recordName: "uploaded-bare")
        try await uploadRecord(to: store, recordName: "uploaded-carrying", encMetadata: Data("theirs".utf8))
        store.metadataToReturn = [CloudKitMediaMetadata(recordName: "seeded-bare", albumID: "album-1",
                                                        mediaID: "seeded-bare", mediaType: .photo,
                                                        createdAt: Date(timeIntervalSince1970: 1_000),
                                                        sizeBytes: 10, creationDeviceID: "other",
                                                        schemaVersion: 1, keyFingerprint: "fingerprint-a",
                                                        recordChangeTag: "tag-seeded")]

        let attachedUploaded = try await store.attachMetadata(recordName: "uploaded-bare", sealed: Data("mine".utf8))
        let attachedSeeded = try await store.attachMetadata(recordName: "seeded-bare", sealed: Data("mine".utf8))
        let present = try await store.attachMetadata(recordName: "uploaded-carrying", sealed: Data("mine".utf8))
        let missing = try await store.attachMetadata(recordName: "ghost", sealed: Data("mine".utf8))
        let seeded = try await store.fetchRecordMetadata(recordName: "seeded-bare")

        guard case .attached = attachedUploaded else { return XCTFail("expected attached, got \(attachedUploaded)") }
        XCTAssertEqual(attachedSeeded, .attached(changeTag: seeded?.recordChangeTag))
        XCTAssertEqual(seeded?.descriptor.encMetadata, Data("mine".utf8))
        XCTAssertEqual(present, .alreadyPresent)
        XCTAssertEqual(missing, .recordMissing)
        XCTAssertEqual(store.attachedMetadata, ["uploaded-bare": Data("mine".utf8), "seeded-bare": Data("mine".utf8)])
        XCTAssertEqual(store.metadataAttachSaveCount, 2)
        XCTAssertEqual(store.callOrder.filter { $0 == .attachMetadata(recordName: "ghost") }.count, 1)
    }

    func testMockStoreConcurrentAttachKeepsTheOtherDevicesValue() async throws {
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = [CloudKitMediaMetadata(recordName: "bare", albumID: "album-1",
                                                        mediaID: "bare", mediaType: .photo,
                                                        createdAt: Date(timeIntervalSince1970: 1_000),
                                                        sizeBytes: 10, creationDeviceID: "other",
                                                        schemaVersion: 1, keyFingerprint: "fingerprint-a",
                                                        recordChangeTag: "tag-seeded")]
        store.simulateConcurrentMetadataAttachOnce(recordName: "bare", theirSealed: Data("theirs".utf8))

        let raced = try await store.attachMetadata(recordName: "bare", sealed: Data("mine".utf8))
        let again = try await store.attachMetadata(recordName: "bare", sealed: Data("mine".utf8))
        let after = try await store.fetchRecordMetadata(recordName: "bare")

        XCTAssertEqual(raced, .alreadyPresent)
        XCTAssertEqual(again, .alreadyPresent)
        XCTAssertEqual(after?.descriptor.encMetadata, Data("theirs".utf8))
        XCTAssertEqual(store.metadataAttachSaveCount, 0, "this device never wrote the record")
    }

    // MARK: - File bytes onto a record

    func testFileMetadataBytesEncryptedOntoARecordReadBackToTheSameBytes() async throws {
        let json = try metadataJSONWithUnknownKey()
        let file = try writeENC2File(metadataJSON: json, keyBytes: key)
        let store = InMemoryCloudKitMediaStore()
        try await uploadRecord(to: store, recordName: recordName)

        let bytes = try await EncryptedMetadataHandler().readMetadataBytes(from: file, keyBytes: key)
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(bytes: try XCTUnwrap(bytes), recordName: recordName, keyBytes: key)
        _ = try await store.attachMetadata(recordName: recordName, sealed: sealed)
        let onRecord = try await store.fetchRecordMetadata(recordName: recordName)?.descriptor.encMetadata

        XCTAssertEqual(openSealedBytes(try XCTUnwrap(onRecord), recordName: recordName), json)
    }
}
