//
//  CloudKitStoreDoubleFidelityTests.swift
//  EncameraCoreTests
//
//  The two `CloudKitMediaStoring` doubles — `MockCloudKitMediaStore` for unit
//  tests and `InMemoryCloudKitMediaStore` behind `-CloudKitMockMode` — must
//  behave like the real store where tests lean on them. Each fault hook is
//  proven here to fire, and to do nothing until it is set.
//

import XCTest
import CloudKit
@testable import EncameraCore

final class CloudKitStoreDoubleFidelityTests: XCTestCase {

    private let sourceAlbum = "album-source"
    private let destinationAlbum = "album-destination"

    // MARK: - Fixtures

    private func metadata(_ recordName: String,
                          albumID: String,
                          tag: String = "tag-seed") -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(
            descriptor: CloudKitMediaRecordDescriptor(albumID: albumID, mediaID: recordName,
                                                      recordName: recordName, mediaType: .photo,
                                                      createdAt: Date(), sizeBytes: 3, keyFingerprint: ""),
            creationDeviceID: "test", schemaVersion: CloudKitSchema.currentSchemaVersion,
            recordChangeTag: tag)
    }

    private func mockWithRecords(_ names: [String]) -> MockCloudKitMediaStore {
        let store = MockCloudKitMediaStore()
        store.metadataToReturn = names.map { metadata($0, albumID: sourceAlbum) }
        return store
    }

    private func upload(recordName: String, albumID: String) throws -> CloudKitMediaUpload {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fidelity-\(UUID().uuidString).enc")
        try Data("abc".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return CloudKitMediaUpload(albumID: albumID, mediaID: recordName, mediaType: .photo,
                                   createdAt: Date(), sizeBytes: 3, encryptedFileURL: url,
                                   encryptedThumbURL: nil, recordName: recordName, keyFingerprint: "")
    }

    private func albumUpload(_ albumID: String, cover: String?) -> CloudKitAlbumUpload {
        CloudKitAlbumUpload(albumID: albumID, encName: "enc-\(albumID)", createdAt: Date(),
                            isHidden: false, keyFingerprint: "fp", coverMediaID: cover)
    }

    private func owner(_ store: MockCloudKitMediaStore, _ recordName: String) -> String? {
        store.metadataToReturn.first { $0.recordName == recordName }?.albumID
    }

    private func tag(_ store: MockCloudKitMediaStore, _ recordName: String) -> String? {
        store.metadataToReturn.first { $0.recordName == recordName }?.recordChangeTag
    }

    private func partialFailures(_ error: Error) -> [String: CKError.Code]? {
        guard case CloudKitMediaStoreError.partial(let failed)? = error as? CloudKitMediaStoreError else {
            return nil
        }
        return failed.mapValues { CKError.Code(rawValue: ($0 as NSError).code) ?? .internalError }
    }

    // MARK: - fetchAlbum and query lag

    func testMockFetchAlbumFindsAnAlbumTheQueryHasNotIndexed() async throws {
        let store = MockCloudKitMediaStore()
        try await store.saveAlbum(albumUpload(destinationAlbum, cover: nil))
        store.albumsMissingFromQuery = [destinationAlbum]
        let queried = try await store.fetchAllAlbums()
        let fetched = try await store.fetchAlbum(albumID: destinationAlbum)
        XCTAssertTrue(queried.isEmpty)
        XCTAssertEqual(fetched?.albumID, destinationAlbum)
    }

    func testInMemoryFetchAlbumFindsAnAlbumTheQueryHasNotIndexed() async throws {
        let store = InMemoryCloudKitMediaStore()
        try await store.saveAlbum(albumUpload(destinationAlbum, cover: nil))
        store.albumIDsMissingFromQuery = [destinationAlbum]
        let queried = try await store.fetchAllAlbums()
        let fetched = try await store.fetchAlbum(albumID: destinationAlbum)
        XCTAssertTrue(queried.isEmpty)
        XCTAssertEqual(fetched?.albumID, destinationAlbum)
    }

    func testDoublesFetchAlbumReturnsNilForAnUnknownOrDeletedAlbum() async throws {
        let mock = MockCloudKitMediaStore()
        let inMemory = InMemoryCloudKitMediaStore()
        for store in [mock, inMemory] as [CloudKitMediaStoring] {
            try await store.saveAlbum(albumUpload(destinationAlbum, cover: nil))
            try await store.deleteAlbum(albumID: destinationAlbum)
            let deleted = try await store.fetchAlbum(albumID: destinationAlbum)
            let unknown = try await store.fetchAlbum(albumID: "never-saved")
            XCTAssertNil(deleted)
            XCTAssertNil(unknown)
        }
    }

    func testQueryLagAndFetchAlbumErrorAreInertByDefault() async throws {
        let mock = MockCloudKitMediaStore()
        let inMemory = InMemoryCloudKitMediaStore()
        for store in [mock, inMemory] as [CloudKitMediaStoring] {
            try await store.saveAlbum(albumUpload(destinationAlbum, cover: nil))
            let queried = try await store.fetchAllAlbums()
            let fetched = try await store.fetchAlbum(albumID: destinationAlbum)
            XCTAssertEqual(queried.map(\.albumID), [destinationAlbum])
            XCTAssertEqual(fetched?.albumID, destinationAlbum)
        }
    }

    func testMockFetchAlbumErrorThrowsAndIsLogged() async {
        let store = MockCloudKitMediaStore()
        store.fetchAlbumError = CloudKitMediaStoreError.retry(after: 1)
        do {
            _ = try await store.fetchAlbum(albumID: destinationAlbum)
            XCTFail("the armed error must throw")
        } catch {}
        XCTAssertEqual(store.callOrder, [.fetchAlbum(albumID: destinationAlbum)])
    }

    // MARK: - saveAlbum keeps the cover

    func testMockSaveAlbumKeepsCoverMediaID() async throws {
        let store = MockCloudKitMediaStore()
        try await store.saveAlbum(albumUpload(destinationAlbum, cover: "cover-media"))
        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.first?.coverMediaID, "cover-media")
    }

    func testInMemorySaveAlbumKeepsCoverMediaID() async throws {
        let store = InMemoryCloudKitMediaStore()
        try await store.saveAlbum(albumUpload(destinationAlbum, cover: "cover-media"))
        let albums = try await store.fetchAllAlbums()
        XCTAssertEqual(albums.first?.coverMediaID, "cover-media")
    }

    func testInMemorySaveAlbumCoverSurvivesARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fidelity-zone-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try await InMemoryCloudKitMediaStore(persistingTo: url)
            .saveAlbum(albumUpload(destinationAlbum, cover: "cover-media"))
        let albums = try await InMemoryCloudKitMediaStore(persistingTo: url).fetchAllAlbums()
        XCTAssertEqual(albums.first?.coverMediaID, "cover-media")
    }

    // MARK: - reassignAlbum bumps the change tag

    func testMockReassignBumpsChangeTagOnEverySave() async throws {
        let store = mockWithRecords(["r1"])
        _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        let first = tag(store, "r1")
        XCTAssertNotEqual(first, "tag-seed")
        _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        XCTAssertNotEqual(tag(store, "r1"), first, "Every save changes the server's change tag")
    }

    func testInMemoryReassignBumpsChangeTagOnEverySave() async throws {
        let store = InMemoryCloudKitMediaStore()
        _ = try await store.upload(try upload(recordName: "r1", albumID: sourceAlbum), progress: { _ in })
        let seeded = try await store.fetchRecordMetadata(recordName: "r1")?.recordChangeTag
        _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        let first = try await store.fetchRecordMetadata(recordName: "r1")?.recordChangeTag
        XCTAssertNotEqual(first, seeded)
        _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        let second = try await store.fetchRecordMetadata(recordName: "r1")?.recordChangeTag
        XCTAssertNotEqual(second, first, "Every save changes the server's change tag")
    }

    // MARK: - reassignFailures

    func testReassignFailuresFailTheWholeBatchAsAPartial() async throws {
        let store = mockWithRecords(["r1", "r2"])
        store.reassignFailures = ["r1"]
        do {
            _ = try await store.reassignAlbum(recordNames: ["r1", "r2"], toAlbumID: destinationAlbum)
            XCTFail("reassignAlbum should throw for a record in reassignFailures")
        } catch {
            XCTAssertEqual(partialFailures(error), ["r1": .serverRejectedRequest, "r2": .batchRequestFailed])
        }
        XCTAssertEqual(owner(store, "r1"), sourceAlbum, "An atomic save that failed moves nothing")
        XCTAssertEqual(owner(store, "r2"), sourceAlbum, "An atomic save that failed moves nothing")
    }

    func testReassignFailuresAreInertByDefault() async throws {
        let store = mockWithRecords(["r1"])
        let notFound = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        XCTAssertEqual(notFound, [])
        XCTAssertEqual(owner(store, "r1"), destinationAlbum)
    }

    // MARK: - reassignNotFound

    func testReassignNotFoundThrowsNotFoundAndMovesNothing() async throws {
        let store = mockWithRecords(["r1", "r2"])
        store.reassignNotFound = ["r2"]
        do {
            _ = try await store.reassignAlbum(recordNames: ["r1", "r2"], toAlbumID: destinationAlbum)
            XCTFail("reassignAlbum should throw for a record in reassignNotFound")
        } catch {
            guard case CloudKitMediaStoreError.notFound? = error as? CloudKitMediaStoreError else {
                return XCTFail("Expected .notFound, got \(error)")
            }
        }
        XCTAssertEqual(owner(store, "r1"), sourceAlbum)
    }

    // MARK: - confirmAlbumOverride

    func testConfirmAlbumOverrideAnswersThroughTheProtocol() async throws {
        let store = mockWithRecords(["r1", "r2"])
        store.confirmAlbumOverride = ["r1": .success("album-elsewhere"),
                                      "r2": .failure(CloudKitMediaStoreError.retry(after: 1))]
        let seam: CloudKitMediaStoring = store
        let answered = try await seam.confirmAlbum(recordName: "r1")
        XCTAssertEqual(answered, "album-elsewhere")
        do {
            _ = try await seam.confirmAlbum(recordName: "r2")
            XCTFail("confirmAlbum should throw the overridden error")
        } catch {
            guard case CloudKitMediaStoreError.retry? = error as? CloudKitMediaStoreError else {
                return XCTFail("Expected .retry, got \(error)")
            }
        }
    }

    func testConfirmAlbumOverrideIsInertByDefault() async throws {
        let store = mockWithRecords(["r1"])
        let seam: CloudKitMediaStoring = store
        let answered = try await seam.confirmAlbum(recordName: "r1")
        XCTAssertEqual(answered, sourceAlbum)
        let missing = try await seam.confirmAlbum(recordName: "absent")
        XCTAssertNil(missing)
    }

    // MARK: - unpublishedParents

    func testUnpublishedParentRejectsUploadsAndReassignsIntoIt() async throws {
        let store = mockWithRecords(["r1"])
        store.unpublishedParents = [destinationAlbum]
        do {
            _ = try await store.upload(try upload(recordName: "new", albumID: destinationAlbum), progress: { _ in })
            XCTFail("upload into an unpublished album should throw")
        } catch {
            XCTAssertEqual(partialFailures(error), ["new": .referenceViolation])
        }
        do {
            _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
            XCTFail("reassign into an unpublished album should throw")
        } catch {
            XCTAssertEqual(partialFailures(error), ["r1": .referenceViolation])
        }
        XCTAssertEqual(owner(store, "r1"), sourceAlbum)
    }

    func testUnpublishedParentsAreInertByDefault() async throws {
        let store = mockWithRecords(["r1"])
        _ = try await store.upload(try upload(recordName: "new", albumID: destinationAlbum), progress: { _ in })
        _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        XCTAssertEqual(owner(store, "r1"), destinationAlbum)
    }

    // MARK: - fetchRecordMetadataErrorAfter

    func testFetchRecordMetadataErrorAfterFailsOnceTheBudgetIsSpent() async throws {
        let store = mockWithRecords(["r1"])
        store.fetchRecordMetadataErrorAfter = (successes: 2, error: CloudKitMediaStoreError.retry(after: 1))
        _ = try await store.fetchRecordMetadata(recordName: "r1")
        _ = try await store.confirmAlbum(recordName: "r1")
        do {
            _ = try await store.fetchRecordMetadata(recordName: "r1")
            XCTFail("the third call should throw")
        } catch {
            guard case CloudKitMediaStoreError.retry? = error as? CloudKitMediaStoreError else {
                return XCTFail("Expected .retry, got \(error)")
            }
        }
    }

    func testFetchRecordMetadataErrorAfterIsInertByDefault() async throws {
        let store = mockWithRecords(["r1"])
        for _ in 0..<5 {
            let fetched = try await store.fetchRecordMetadata(recordName: "r1")
            XCTAssertNotNil(fetched)
        }
    }

    // MARK: - callOrder

    func testCallOrderLogsEveryCallInOrderIncludingFailedOnes() async throws {
        let store = mockWithRecords(["r1"])
        store.reassignFailures = ["r1"]
        try await store.saveAlbum(albumUpload(destinationAlbum, cover: nil))
        _ = try? await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        _ = try await store.confirmAlbum(recordName: "r1")
        try await store.delete(recordName: "r1")
        XCTAssertEqual(store.callOrder, [
            .saveAlbum(albumID: destinationAlbum),
            .reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum),
            .confirmAlbum(recordName: "r1"),
            .fetchRecordMetadata(recordName: "r1"),
            .delete(recordName: "r1"),
        ])
    }

    func testCallOrderIsEmptyBeforeAnyCall() {
        XCTAssertEqual(MockCloudKitMediaStore().callOrder, [])
    }

    // MARK: - Per-record upload failure (unit double)

    func testUploadFailuresFailOnlyTheNamedRecord() async throws {
        let store = MockCloudKitMediaStore()
        store.uploadFailures = ["bad": CloudKitMediaStoreError.quotaExceeded]
        _ = try await store.upload(try upload(recordName: "good", albumID: destinationAlbum), progress: { _ in })
        for _ in 0..<2 {
            do {
                _ = try await store.upload(try upload(recordName: "bad", albumID: destinationAlbum), progress: { _ in })
                XCTFail("upload of a record in uploadFailures should throw")
            } catch {
                guard case CloudKitMediaStoreError.quotaExceeded? = error as? CloudKitMediaStoreError else {
                    return XCTFail("Expected .quotaExceeded, got \(error)")
                }
            }
        }
        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 1, fingerprints: [:]), "A failed upload stores nothing")
    }

    func testUploadFailuresAreInertByDefault() async throws {
        let store = MockCloudKitMediaStore()
        _ = try await store.upload(try upload(recordName: "bad", albumID: destinationAlbum), progress: { _ in })
        let census = try await store.fetchFingerprintCensus()
        XCTAssertEqual(census, .counted(mediaCount: 1, fingerprints: [:]))
    }

    // MARK: - In-app mock faults

    private func inMemoryWithRecord(_ recordName: String) async throws -> InMemoryCloudKitMediaStore {
        let store = InMemoryCloudKitMediaStore()
        _ = try await store.upload(try upload(recordName: recordName, albumID: sourceAlbum), progress: { _ in })
        return store
    }

    func testInMemoryFailNextUploadByRecordNameFailsThatRecordOnce() async throws {
        let store = InMemoryCloudKitMediaStore()
        store.failNextUpload(recordName: "bad")
        _ = try await store.upload(try upload(recordName: "good", albumID: destinationAlbum), progress: { _ in })
        do {
            _ = try await store.upload(try upload(recordName: "bad", albumID: destinationAlbum), progress: { _ in })
            XCTFail("the first upload of the named record should throw")
        } catch {
            guard case CloudKitMediaStoreError.quotaExceeded? = error as? CloudKitMediaStoreError else {
                return XCTFail("Expected .quotaExceeded, got \(error)")
            }
        }
        XCTAssertEqual(store.liveRecordNames, ["good"])
        _ = try await store.upload(try upload(recordName: "bad", albumID: destinationAlbum), progress: { _ in })
        XCTAssertEqual(store.liveRecordNames, ["bad", "good"])
    }

    func testInMemoryFailsEveryReassignMovesNothing() async throws {
        let store = try await inMemoryWithRecord("r1")
        store.failsEveryReassign = true
        do {
            _ = try await store.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
            XCTFail("reassignAlbum should throw while failsEveryReassign is set")
        } catch {
            guard case CloudKitMediaStoreError.retry? = error as? CloudKitMediaStoreError else {
                return XCTFail("Expected .retry, got \(error)")
            }
        }
        let owner = try await store.fetchRecordMetadata(recordName: "r1")?.albumID
        XCTAssertEqual(owner, sourceAlbum)
    }

    func testInMemoryFailsEveryConfirmThrowsThroughTheProtocol() async throws {
        let store = try await inMemoryWithRecord("r1")
        store.failsEveryConfirm = true
        let seam: CloudKitMediaStoring = store
        do {
            _ = try await seam.confirmAlbum(recordName: "r1")
            XCTFail("confirmAlbum should throw while failsEveryConfirm is set")
        } catch {
            guard case CloudKitMediaStoreError.retry? = error as? CloudKitMediaStoreError else {
                return XCTFail("Expected .retry, got \(error)")
            }
        }
        let fetched = try await seam.fetchRecordMetadata(recordName: "r1")
        XCTAssertNotNil(fetched, "Only confirmAlbum fails")
    }

    func testInMemoryFaultsAreInertByDefault() async throws {
        let store = try await inMemoryWithRecord("r1")
        let seam: CloudKitMediaStoring = store
        let before = try await seam.confirmAlbum(recordName: "r1")
        XCTAssertEqual(before, sourceAlbum)
        _ = try await seam.reassignAlbum(recordNames: ["r1"], toAlbumID: destinationAlbum)
        let after = try await seam.confirmAlbum(recordName: "r1")
        XCTAssertEqual(after, destinationAlbum)
    }

    // MARK: - Existing chunks

    private func enc3(_ plaintext: Data) throws -> (url: URL, header: SeekableEncryptedHeader) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fidelity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("plain")
        try plaintext.write(to: source)
        let url = dir.appendingPathComponent("blob.enc3")
        let header = try SeekableEncryptedWriter(keyBytes: [UInt8](repeating: 7, count: 32), chunkSize: 100)
            .encrypt(source: source, destination: url, metadata: nil)
        return (url, header)
    }

    private func chunkedUpload(_ blob: (url: URL, header: SeekableEncryptedHeader),
                               existingChunks: ExistingChunkPolicy) -> CloudKitMediaUpload {
        CloudKitMediaUpload(descriptor: CloudKitMediaRecordDescriptor(albumID: sourceAlbum, mediaID: "vid",
                                                                      recordName: "vid#2", mediaType: .video,
                                                                      createdAt: Date(), sizeBytes: 500,
                                                                      keyFingerprint: "",
                                                                      chunkCount: blob.header.chunkCount,
                                                                      plaintextLength: Int64(blob.header.plaintextLength)),
                            encryptedFileURL: blob.url, encryptedThumbURL: nil, existingChunks: existingChunks)
    }

    func testInMemoryChunkStoreKeepsExistingChunksUnlessAskedToOverwrite() async throws {
        let plaintext = Data((0..<500).map { UInt8($0 % 251) })
        let first = try enc3(plaintext)
        let second = try enc3(plaintext)
        let store = InMemoryChunkedBlobStore()
        try await store.uploadChunks(enc3FileURL: first.url, mediaRecordName: "m", progress: { _ in })
        let firstChunk = try await store.fetchChunk(mediaRecordName: "m", index: 0)

        try await store.uploadChunks(enc3FileURL: second.url, mediaRecordName: "m", progress: { _ in })
        let probed = try await store.fetchChunk(mediaRecordName: "m", index: 0)
        XCTAssertEqual(probed, firstChunk, "resume-by-probe keeps a chunk already stored, as the real store does")

        try await store.uploadChunks(enc3FileURL: second.url, mediaRecordName: "m",
                                     existingChunks: .overwrite, progress: { _ in })
        let overwritten = try await store.fetchChunk(mediaRecordName: "m", index: 0)
        XCTAssertNotEqual(overwritten, firstChunk, "overwrite rewrites it")
    }

    func testInMemoryStoreRefusesToOverwriteTheChunksOfACommittedRecord() async throws {
        let plaintext = Data((0..<500).map { UInt8($0 % 251) })
        let store = InMemoryCloudKitMediaStore()
        _ = try await store.upload(chunkedUpload(try enc3(plaintext), existingChunks: .resumeByProbe), progress: { _ in })
        do {
            _ = try await store.upload(chunkedUpload(try enc3(plaintext), existingChunks: .overwrite), progress: { _ in })
            XCTFail("an overwrite under a committed record must be refused")
        } catch CloudKitMediaStoreError.conflict {
        }
    }

    func testInMemoryStoreOverwritesWhenNothingIsCommitted() async throws {
        let plaintext = Data((0..<500).map { UInt8($0 % 251) })
        let store = InMemoryCloudKitMediaStore()
        _ = try await store.upload(chunkedUpload(try enc3(plaintext), existingChunks: .overwrite), progress: { _ in })
        let fetched = try await store.fetchRecordMetadata(recordName: "vid#2")
        XCTAssertNotNil(fetched)
    }

    func testInMemoryChunkedRecordReportsItsCiphertextLengthFromItsHeader() async throws {
        let plaintext = Data((0..<500).map { UInt8($0 % 251) })
        let blob = try enc3(plaintext)
        let store = InMemoryCloudKitMediaStore()
        _ = try await store.upload(chunkedUpload(blob, existingChunks: .resumeByProbe), progress: { _ in })

        let fetched = try await store.fetchRecordMetadata(recordName: "vid#2")

        XCTAssertEqual(fetched?.expectedCiphertextLength, blob.url.fileSizeBytes(),
                       "the record carries its header, as the real one does, so its ciphertext length is known")
    }
}
