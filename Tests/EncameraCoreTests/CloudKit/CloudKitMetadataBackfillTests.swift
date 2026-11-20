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

    /// The ENC2 prologue and metadata section for `json`, encrypted exactly, as
    /// `EncryptedMetadataHandler.buildV2Header` lays it out.
    private func enc2Header(metadataJSON json: Data, keyBytes: [UInt8]) throws -> Data {
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
        return file
    }

    /// An ENC2 file whose metadata section encrypts `json` exactly, followed by
    /// content bytes the metadata read never touches.
    private func writeENC2File(metadataJSON json: Data, keyBytes: [UInt8]) throws -> URL {
        var file = try enc2Header(metadataJSON: json, keyBytes: keyBytes)
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

    // MARK: - Backfill when a blob lands

    /// The capture date an older build stamped as the record's `createdAt`, and
    /// so its "Date Added" until the record gains `encMetadata`.
    private static let createdAt = Date(timeIntervalSince1970: 1_500_000_000)
    /// The encryption date in `knownMetadata()`: the record's real "Date Added".
    private static let realDateAdded = Date(timeIntervalSince1970: 1_700_000_000)
    private static let foreignKey = PrivateKey(keyBytes: Array(repeating: UInt8(7), count: 32), creationDate: Date())
    private static let unheldKey = PrivateKey(keyBytes: Array(repeating: UInt8(3), count: 32), creationDate: Date())

    private var albumKey: PrivateKey { PrivateKey(keyBytes: key, creationDate: Date()) }

    /// One device holding a CloudKit album and the records it synced.
    private struct BackfillDevice {
        let album: Album
        let store: MockCloudKitMediaStore
        let access: CloudKitFileAccess
        let id: String
        let recordName: String
    }

    /// A real ENC2 photo under `fileKey` whose metadata section encrypts
    /// `metadataJSON` exactly: a genuine file's content after a prologue made
    /// from those bytes, so the photo still decrypts.
    private func encryptedPhoto(id: String, fileKey: PrivateKey, metadataJSON: Data) async throws -> Data {
        let tmp = try makeDirectory().appendingPathComponent("\(id).enc")
        let cleartext = CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: id)
        _ = try await SecretFileHandlerV2(keyBytes: fileKey.keyBytes, source: cleartext, targetURL: tmp)
            .encryptWithMetadata(EncryptedFileMetadata())
        let genuine = try Data(contentsOf: tmp)
        let lengthOffset = EncryptedFileFormat.metadataLengthOffset
        let metadataLength = genuine.subdata(in: lengthOffset..<(lengthOffset + EncryptedFileFormat.metadataLengthSize))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let contentStart = lengthOffset + EncryptedFileFormat.metadataLengthSize + Int(metadataLength)
        var file = try enc2Header(metadataJSON: metadataJSON, keyBytes: fileKey.keyBytes)
        file.append(genuine.subdata(in: contentStart..<genuine.count))
        return file
    }

    /// A record as an older build saved it: dated by `createdAt`, sealed with no
    /// `encMetadata` unless given.
    private func olderRecord(album: Album, id: String, createdAt: Date = CloudKitMetadataBackfillTests.createdAt, sizeBytes: Int64 = 100,
                             keyFingerprint: String, encMetadata: Data? = nil) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(recordName: MediaRecordName.componentRecordName(mediaID: id, type: .photo),
                              albumID: album.albumID!, mediaID: id, mediaType: .photo,
                              createdAt: createdAt, sizeBytes: sizeBytes, creationDeviceID: "older-build",
                              schemaVersion: 1, keyFingerprint: keyFingerprint, recordChangeTag: "tag-older",
                              encMetadata: encMetadata)
    }

    /// A device on which an album under `albumKey` holds one photo an older
    /// build saved: its blob is ENC2 under `fileKey` (the album's key when nil)
    /// carrying `metadataJSON`, and its record carries `encMetadata` only when
    /// given. The device holds `heldKeys` besides the album's key, and has synced
    /// the record and `otherRecords` into its index, but has not downloaded the
    /// blob.
    private func deviceWithAnOlderRecord(fileKey: PrivateKey? = nil,
                                         heldKeys: [PrivateKey] = [],
                                         metadataJSON: Data? = nil,
                                         encMetadata: Data? = nil,
                                         otherRecords: (Album) -> [CloudKitMediaMetadata] = { _ in [] }) async throws -> BackfillDevice {
        let album = Album(name: "metadata-backfill-\(UUID().uuidString)", storageOption: .cloudKit,
                          creationDate: Date(), key: albumKey, albumID: UUID().uuidString)
        let keyManager = DemoKeyManager()
        keyManager.currentKey = album.key
        keyManager.storedKeysValue = [album.key] + heldKeys
        let albumManager = MockAlbumManager(keyManager: keyManager)
        albumManager.albumsOnDisk = [album]
        let store = MockCloudKitMediaStore()
        let access = await CloudKitFileAccess(album: album, albumManager: albumManager, store: store)
        let id = UUID().uuidString
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        let albumBaseURL = CloudKitStorageModel(album: album).baseURL
        let indexURL = MediaIndexStore.indexURL(for: album)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: albumBaseURL)
            try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: CloudKitStorageModel.previewURL(forMediaID: id))
            try? FileManager.default.removeItem(at: URL.tempMediaDirectory.appendingPathComponent(id)
                .appendingPathExtension(MediaType.photo.decryptedFileExtension))
        }

        let blobKey = fileKey ?? album.key
        let json = try metadataJSON ?? EncryptedMetadataHandler.encodeMetadata(knownMetadata())
        let blob = try await encryptedPhoto(id: id, fileKey: blobKey, metadataJSON: json)
        let record = olderRecord(album: album, id: id, sizeBytes: Int64(blob.count),
                                 keyFingerprint: blobKey.keyFingerprint, encMetadata: encMetadata)
        let records = [record] + otherRecords(album)
        store.blobContents = blob
        store.metadataToReturn = records
        store.changeSet = CloudKitChangeSet(changed: records, deleted: [], token: nil, moreComing: false)
        _ = await access.reconcile()
        return BackfillDevice(album: album, store: store, access: access, id: id, recordName: recordName)
    }

    /// Opens the device's photo the way the viewer does, and waits for the
    /// background work the open starts.
    private func openPhoto(on device: BackfillDevice) async throws {
        let listed = await device.access.enumerate()
        let media = try XCTUnwrap(listed.first { $0.id == device.id }, "the device's index lists the photo")
        _ = try await device.access.loadMedia(media: media, progress: { _ in })
        await device.access.awaitMetadataBackfills()
        await device.access.awaitThumbnailRepairs()
    }

    private func encMetadataOnRecord(of device: BackfillDevice) async throws -> Data? {
        try await device.store.fetchRecordMetadata(recordName: device.recordName)?.encMetadata
    }

    private func attachCalls(on device: BackfillDevice) -> Int {
        device.store.callOrder.filter { $0 == .attachMetadata(recordName: device.recordName) }.count
    }

    private func indexEntry(of device: BackfillDevice, id: String? = nil) throws -> MediaIndexEntry {
        let wanted = id ?? device.id
        return try XCTUnwrap(MediaIndexStore.storedEntries(for: device.album).first { $0.id == wanted })
    }

    /// Metadata other than `knownMetadata()`, as another device or an edit sealed it.
    private func otherDevicesMetadata() -> EncryptedFileMetadata {
        var metadata = knownMetadata()
        metadata.encryptionDate = Date(timeIntervalSince1970: 1_650_000_000)
        metadata.originalFilename = "IMG_OTHER.HEIC"
        return metadata
    }

    func testBlobLandingBackfillsAMissingField() async throws {
        let device = try await deviceWithAnOlderRecord()
        let before = try await encMetadataOnRecord(of: device)
        XCTAssertNil(before, "precondition: the older record has no encMetadata")

        try await openPhoto(on: device)

        XCTAssertEqual(device.store.fetchBlobCount, 1, "the blob landed through a CloudKit fetch")
        let sealed = try await encMetadataOnRecord(of: device)
        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(try XCTUnwrap(sealed, "the record gained encMetadata"),
                                                                  recordName: device.recordName, keyBytes: key),
                       knownMetadata(), "the record's encMetadata opens to the file's metadata")
        XCTAssertEqual(device.store.metadataAttachSaveCount, 1)
    }

    func testBackfillNeverOverwritesAnExistingField() async throws {
        let theirs = try CloudKitRecordMetadataHandler.encryptMetadata(otherDevicesMetadata(), recordName: "\(UUID())", keyBytes: key)
        let device = try await deviceWithAnOlderRecord(encMetadata: theirs)

        try await openPhoto(on: device)

        let onRecord = try await encMetadataOnRecord(of: device)
        XCTAssertEqual(onRecord, theirs, "a record that has encMetadata keeps it, even when the file differs")
        XCTAssertEqual(device.store.metadataAttachSaveCount, 0)
        XCTAssertEqual(attachCalls(on: device), 0, "a record synced with the field is not even asked")
    }

    /// A copy already on the device is backfilled when this session knows its
    /// record has no `encMetadata`: the read itself asks nothing, and the
    /// backfill it starts attaches.
    func testResidentCopyOfARecordKnownToLackTheFieldIsBackfilled() async throws {
        let device = try await deviceWithAnOlderRecord()
        device.store.attachMetadataError = CloudKitMediaStoreError.underlying(URLError(.networkConnectionLost))
        try await openPhoto(on: device)
        let afterFailedAttach = try await encMetadataOnRecord(of: device)
        XCTAssertNil(afterFailedAttach, "precondition: the first open's attach failed")
        device.store.attachMetadataError = nil

        try await openPhoto(on: device)

        XCTAssertEqual(device.store.fetchBlobCount, 1, "the second open read the resident copy")
        let sealed = try await encMetadataOnRecord(of: device)
        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(try XCTUnwrap(sealed, "the record gained encMetadata"),
                                                                  recordName: device.recordName, keyBytes: key),
                       knownMetadata())
        XCTAssertEqual(attachCalls(on: device), 2)
        XCTAssertEqual(device.store.metadataAttachSaveCount, 1)
    }

    func testBackfillSkipsRecordsQueuedForUpload() async throws {
        let device = try await deviceWithAnOlderRecord()
        let queuedID = UUID().uuidString
        let queuedRecordName = MediaRecordName.componentRecordName(mediaID: queuedID, type: .photo)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: CloudKitStorageModel.previewURL(forMediaID: queuedID))
            try? FileManager.default.removeItem(at: URL.tempMediaDirectory.appendingPathComponent(queuedID)
                .appendingPathExtension(MediaType.photo.decryptedFileExtension))
        }
        device.store.uploadFailures[queuedRecordName] = CloudKitMediaStoreError.retry(after: 60)
        device.store.metadataToReturn.append(olderRecord(album: device.album, id: queuedID,
                                                         keyFingerprint: device.album.key.keyFingerprint))
        let saved = try await device.access.save(media: try InteractableMedia(underlyingMedia: [
            CleartextMedia(source: .data(TestImageData.png()), mediaType: .photo, id: queuedID)
        ]), metadata: knownMetadata(), progress: { _ in })
        let queued = try XCTUnwrap(saved)

        _ = try await device.access.loadMedia(media: queued, progress: { _ in })
        await device.access.awaitMetadataBackfills()
        await device.access.awaitThumbnailRepairs()

        XCTAssertEqual(device.store.callOrder.filter { $0 == .attachMetadata(recordName: queuedRecordName) }.count, 0,
                       "a capture still in the upload queue is never backfilled; its upload carries its metadata")
        XCTAssertEqual(device.store.metadataAttachSaveCount, 0)
    }

    func testBackfillCopiesUnknownMetadataKeysVerbatim() async throws {
        let json = try metadataJSONWithUnknownKey()
        let device = try await deviceWithAnOlderRecord(metadataJSON: json)

        try await openPhoto(on: device)

        let onRecord = try await encMetadataOnRecord(of: device)
        let sealed = try XCTUnwrap(onRecord)
        XCTAssertEqual(openSealedBytes(sealed, recordName: device.recordName), json,
                       "the record carries the file's metadata bytes, a key this build does not know included")
    }

    func testConcurrentBackfillConflictKeepsTheFirstWrite() async throws {
        let device = try await deviceWithAnOlderRecord()
        let theirs = try CloudKitRecordMetadataHandler.encryptMetadata(otherDevicesMetadata(), recordName: device.recordName, keyBytes: key)
        device.store.simulateConcurrentMetadataAttachOnce(recordName: device.recordName, theirSealed: theirs)

        try await openPhoto(on: device)
        try await openPhoto(on: device)

        let onRecord = try await encMetadataOnRecord(of: device)
        XCTAssertEqual(onRecord, theirs, "the other device's write landed first and is kept")
        XCTAssertEqual(device.store.metadataAttachSaveCount, 0, "this device saved nothing over it")
        XCTAssertEqual(attachCalls(on: device), 1,
                       "one attempt meets the conflict, and a later open does not try again")
    }

    func testBackfillReordersTheIndexEntry() async throws {
        let laterID = UUID().uuidString
        let laterAdded = Date(timeIntervalSince1970: 1_600_000_000)
        let device = try await deviceWithAnOlderRecord(otherRecords: { album in
            [self.olderRecord(album: album, id: laterID, createdAt: laterAdded,
                              keyFingerprint: album.key.keyFingerprint)]
        })
        let newestFirst = MediaSortOption.dateEncrypted(ascending: false)
        let orderBefore = await device.access.enumerateMediaWithMetadata(sortBy: newestFirst, filterBy: .all).map(\.media.id)
        XCTAssertEqual(try indexEntry(of: device).dateEncrypted, Self.createdAt,
                       "before: the older record is dated by its createdAt")
        XCTAssertEqual(orderBefore, [laterID, device.id])

        try await openPhoto(on: device)

        let orderAfter = await device.access.enumerateMediaWithMetadata(sortBy: newestFirst, filterBy: .all).map(\.media.id)
        XCTAssertEqual(try indexEntry(of: device).dateEncrypted, Self.realDateAdded,
                       "after: the entry is dated by the real encryption date, replacing createdAt")
        XCTAssertEqual(try indexEntry(of: device).dateTaken, Self.createdAt)
        XCTAssertEqual(orderAfter, [device.id, laterID], "the item moved to its real place under Date Added")
    }

    func testBackfillSealsARecordUnderAForeignKeyWithThatKey() async throws {
        let device = try await deviceWithAnOlderRecord(fileKey: Self.foreignKey, heldKeys: [Self.foreignKey])

        try await openPhoto(on: device)

        let onRecord = try await encMetadataOnRecord(of: device)
        let sealed = try XCTUnwrap(onRecord, "the record gained encMetadata")
        XCTAssertEqual(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: device.recordName,
                                                                  keyBytes: Self.foreignKey.keyBytes),
                       knownMetadata(), "sealed under the key the record's blob is encrypted with")
        XCTAssertNil(CloudKitRecordMetadataHandler.readMetadata(sealed, recordName: device.recordName, keyBytes: key),
                     "not under the album's key")
        XCTAssertEqual(try indexEntry(of: device).dateEncrypted, Self.realDateAdded,
                       "the entry is re-dated with the key the metadata is sealed under")
    }

    func testBackfillSkipsAFileNoHeldKeyOpens() async throws {
        let device = try await deviceWithAnOlderRecord(fileKey: Self.unheldKey)

        let listed = await device.access.enumerate()
        let media = try XCTUnwrap(listed.first { $0.id == device.id })
        _ = try? await device.access.loadMedia(media: media, progress: { _ in })
        await device.access.awaitMetadataBackfills()

        XCTAssertEqual(device.store.fetchBlobCount, 1, "precondition: the blob landed")
        XCTAssertEqual(attachCalls(on: device), 0)
        let onRecord = try await encMetadataOnRecord(of: device)
        XCTAssertNil(onRecord)
    }

    func testBackfillLogNamesTheRecordWithoutMetadataValues() async throws {
        let wasCapturing = DebugLogBuffer.shared.isCapturing
        DebugLogBuffer.shared.setCapturing(true)
        DebugLogBuffer.shared.clear()
        defer { DebugLogBuffer.shared.setCapturing(wasCapturing) }
        let device = try await deviceWithAnOlderRecord()

        try await openPhoto(on: device)

        let lines = DebugLogBuffer.shared.snapshot(newestFirst: false).map(\.message)
        XCTAssertTrue(lines.contains { $0.contains("metadataBackfill attached recordName=\(device.recordName)") },
                      "the backfill log names the record and its outcome")
        let metadata = knownMetadata()
        let values = [metadata.originalFilename, metadata.captureDate.map { "\($0)" },
                      metadata.encryptionDate.map { "\($0)" }].compactMap { $0 }
        for value in values {
            XCTAssertFalse(lines.contains { $0.contains(value) }, "a log line carries the metadata value \(value)")
        }
    }

    func testBackfillingDeviceSyncingItsOwnWriteBackChangesNothing() async throws {
        let device = try await deviceWithAnOlderRecord()
        try await openPhoto(on: device)
        let afterBackfill = try indexEntry(of: device)
        let ownWrite = try XCTUnwrap(device.store.changeSet.changed.first { $0.recordName == device.recordName }?.encMetadata,
                                     "precondition: the change feed now carries this device's write")

        _ = await device.access.reconcile()

        XCTAssertEqual(device.store.metadataAttachSaveCount, 1, "the record is attached once")
        XCTAssertEqual(attachCalls(on: device), 1, "its own write coming back is not attached again")
        let onRecord = try await encMetadataOnRecord(of: device)
        XCTAssertEqual(onRecord, ownWrite)
        XCTAssertEqual(try indexEntry(of: device), afterBackfill,
                       "re-applying the same metadata leaves the entry as it was")
    }

    // MARK: - Every device re-dates a record that gained metadata

    /// The key of every unlocked album `CloudKitSyncCoordinator.forTesting` adds.
    private static let syncAlbumKey = MockAlbumManager.testAlbumKey.keyBytes

    /// One device's coordinator over the unlocked album `albumID`, with an
    /// index of its own.
    private struct SyncDevice {
        let coordinator: CloudKitSyncCoordinator
        let store: MockCloudKitMediaStore
        let index: MediaIndexStore
        let albumID: String
    }

    private func syncDevice() throws -> SyncDevice {
        let root = try makeDirectory()
        let albumID = "sync-album-\(UUID().uuidString)"
        let index = MediaIndexStore(keyBytes: Self.syncAlbumKey, indexURL: root.appendingPathComponent("album.encindex"))
        let store = MockCloudKitMediaStore()
        let deleteSuite = "metadata-backfill-delete-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: deleteSuite) }
        let (coordinator, _) = CloudKitSyncCoordinator.forTesting(
            albums: [(albumID, index, nil)],
            store: store,
            cache: CloudKitBlobCache(baseDir: root.appendingPathComponent("cache", isDirectory: true),
                                     maxBytes: 100 * 1024 * 1024),
            bus: FileOperationBus(),
            uploadQueue: CloudKitUploadQueue(baseDir: root.appendingPathComponent("queue", isDirectory: true)),
            deleteQueue: CloudKitMediaDeleteQueue(suiteName: deleteSuite))
        return SyncDevice(coordinator: coordinator, store: store, index: index, albumID: albumID)
    }

    /// Puts `records` in the device's zone and change feed.
    private func serve(_ records: [CloudKitMediaMetadata], on device: SyncDevice) {
        device.store.metadataToReturn = records
        device.store.changeSet = CloudKitChangeSet(changed: records, deleted: [], token: nil, moreComing: false)
    }

    private func entry(_ id: String, in index: MediaIndexStore) async throws -> MediaIndexEntry {
        let entries = await index.reloadFromDisk()?.entries ?? []
        return try XCTUnwrap(entries.first { $0.id == id }, "the index holds \(id)")
    }

    func testSyncedBackfilledRecordReDatesAnOlderEntry() async throws {
        let device = try syncDevice()
        let id = UUID().uuidString
        let laterID = UUID().uuidString
        let laterAdded = Date(timeIntervalSince1970: 1_600_000_000)
        try await device.index.upsert([
            MediaIndexEntry(id: id, hasPhotoComponent: true, hasVideoComponent: false,
                            keys: MediaSortKeys(recordCreatedAt: Self.createdAt, componentType: .photo)),
            MediaIndexEntry(id: laterID, hasPhotoComponent: true, hasVideoComponent: false,
                            keys: MediaSortKeys(recordCreatedAt: laterAdded, componentType: .photo))
        ])
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: .photo)
        let sealed = try CloudKitRecordMetadataHandler.encryptMetadata(knownMetadata(), recordName: recordName, keyBytes: Self.syncAlbumKey)
        let backfilledElsewhere = CloudKitMediaMetadata(recordName: recordName, albumID: device.albumID, mediaID: id,
                                                        mediaType: .photo, createdAt: Self.createdAt, sizeBytes: 100,
                                                        creationDeviceID: "older-build", schemaVersion: 1,
                                                        keyFingerprint: "fingerprint-a", recordChangeTag: "tag-backfilled",
                                                        encMetadata: sealed)
        let later = CloudKitMediaMetadata(recordName: MediaRecordName.componentRecordName(mediaID: laterID, type: .photo),
                                          albumID: device.albumID, mediaID: laterID, mediaType: .photo,
                                          createdAt: laterAdded, sizeBytes: 100, creationDeviceID: "older-build",
                                          schemaVersion: 1, keyFingerprint: "fingerprint-a", recordChangeTag: "tag-later")
        serve([backfilledElsewhere, later], on: device)
        let newestFirst = { (entries: [MediaIndexEntry]) in
            entries.sorted { ($0.dateEncrypted ?? .distantPast) > ($1.dateEncrypted ?? .distantPast) }.map(\.id)
        }
        let orderBefore = newestFirst(await device.index.reloadFromDisk()?.entries ?? [])
        XCTAssertEqual(orderBefore, [laterID, id], "before: the entry sorts by its record's createdAt")

        try await device.coordinator.sync()

        let redated = try await entry(id, in: device.index)
        XCTAssertEqual(redated.dateEncrypted, Self.realDateAdded,
                       "the record's encMetadata replaces the dates the entry was indexed with")
        XCTAssertEqual(redated.dateTaken, Self.createdAt)
        let orderAfter = newestFirst(await device.index.reloadFromDisk()?.entries ?? [])
        XCTAssertEqual(orderAfter, [id, laterID],
                       "the item moved to its real place under Date Added on a device that never backfilled it")
        XCTAssertEqual(device.store.metadataAttachSaveCount, 0, "this device writes nothing")

        try await device.coordinator.sync()

        let resynced = try await entry(id, in: device.index)
        XCTAssertEqual(resynced, redated, "syncing the same record again changes nothing")
    }

    func testSyncedRecordWithoutReadableMetadataMergesAndKeepsTheEntrysDates() async throws {
        let device = try syncDevice()
        let fieldsOnlyID = UUID().uuidString
        let foreignID = UUID().uuidString
        let indexedDate = Date(timeIntervalSince1970: 1_650_000_000)
        var keys = MediaSortKeys(metadata: knownMetadata(), componentType: .photo)
        keys.dateAdded = indexedDate
        try await device.index.upsert([
            MediaIndexEntry(id: fieldsOnlyID, hasPhotoComponent: true, hasVideoComponent: false, keys: keys),
            MediaIndexEntry(id: foreignID, hasPhotoComponent: true, hasVideoComponent: false, keys: keys)
        ])
        let fieldsOnly = CloudKitMediaMetadata(recordName: MediaRecordName.componentRecordName(mediaID: fieldsOnlyID, type: .photo),
                                               albumID: device.albumID, mediaID: fieldsOnlyID, mediaType: .photo,
                                               createdAt: Self.createdAt, sizeBytes: 100, creationDeviceID: "older-build",
                                               schemaVersion: 1, keyFingerprint: "fingerprint-a", recordChangeTag: "tag-1")
        let foreignName = MediaRecordName.componentRecordName(mediaID: foreignID, type: .photo)
        let underForeignKey = CloudKitMediaMetadata(recordName: foreignName, albumID: device.albumID, mediaID: foreignID,
                                                    mediaType: .photo, createdAt: Self.createdAt, sizeBytes: 100,
                                                    creationDeviceID: "older-build", schemaVersion: 1,
                                                    keyFingerprint: "fingerprint-b", recordChangeTag: "tag-2",
                                                    encMetadata: try CloudKitRecordMetadataHandler.encryptMetadata(otherDevicesMetadata(),
                                                                                                                   recordName: foreignName,
                                                                                                                   keyBytes: otherKey))
        serve([fieldsOnly, underForeignKey], on: device)

        try await device.coordinator.sync()

        let fieldsOnlyEntry = try await entry(fieldsOnlyID, in: device.index)
        XCTAssertEqual(fieldsOnlyEntry.dateEncrypted, indexedDate,
                       "keys from record fields merge, so the entry keeps its dates")
        let foreignEntry = try await entry(foreignID, in: device.index)
        XCTAssertEqual(foreignEntry.dateEncrypted, indexedDate,
                       "metadata the album key does not open falls back to record fields, which merge")
    }
}
