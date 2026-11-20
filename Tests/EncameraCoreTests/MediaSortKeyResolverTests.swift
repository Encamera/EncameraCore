//
//  MediaSortKeyResolverTests.swift
//  EncameraCoreTests
//
//  How the resolver fills each sort key from the first source that has it, and
//  what each source reads.
//

import XCTest
@testable import EncameraCore

final class MediaSortKeyResolverTests: XCTestCase {

    private let taken = Date(timeIntervalSince1970: 1_500_000_000)
    private let added = Date(timeIntervalSince1970: 1_600_000_000)
    private let recordCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let key = PrivateKey(keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaSortKeyResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Helpers

    /// A source that answers with fixed keys and counts how often it is asked.
    private actor StubSortKeySource: MediaSortKeySource {
        private let answer: MediaSortKeys?
        private(set) var callCount = 0

        init(_ answer: MediaSortKeys?) {
            self.answer = answer
        }

        func sortKeys(for request: MediaSortKeyRequest) async -> MediaSortKeys? {
            callCount += 1
            return answer
        }
    }

    private func request(type: MediaType = .photo,
                         fileURL: URL? = nil,
                         record: CloudKitMediaRecordDescriptor? = nil) -> MediaSortKeyRequest {
        MediaSortKeyRequest(mediaID: "a", componentType: type, fileURL: fileURL, record: record)
    }

    private func descriptor(type: MediaType = .photo, createdAt: Date) -> CloudKitMediaRecordDescriptor {
        CloudKitMediaRecordDescriptor(albumID: "album", mediaID: "a", mediaType: type,
                                      createdAt: createdAt, sizeBytes: 1, keyFingerprint: "")
    }

    /// An ENC2 photo whose embedded metadata carries the given dates.
    private func encryptedPhoto(captureDate: Date?, encryptionDate: Date?, isScreenshot: Bool = false) async throws -> URL {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = captureDate
        metadata.encryptionDate = encryptionDate
        if isScreenshot {
            metadata.contentAnalysis = EncryptedFileMetadata.ContentAnalysis(isScreenshot: true)
        }
        let source = CleartextMedia(source: Data((0..<4096).map { UInt8($0 % 251) }), mediaType: .photo, id: "a")
        let url = tempDirectory.appendingPathComponent("a.\(MediaType.photo.encryptedFileExtension)")
        _ = try await SecretFileHandlerV2(keyBytes: key.keyBytes, source: source, targetURL: url)
            .encryptWithMetadata(metadata)
        return url
    }

    // MARK: - Resolver

    func testResolverStopsAskingOnceEveryValueIsSet() async {
        let first = StubSortKeySource(MediaSortKeys(dateAdded: added, dateTaken: taken,
                                                    subtype: .screenshot, source: .encryptedMetadata))
        let second = StubSortKeySource(MediaSortKeys(recordCreatedAt: recordCreatedAt, componentType: .photo))
        let keys = await MediaSortKeyResolver(sources: [first, second]).sortKeys(for: request())
        let firstCalls = await first.callCount
        let secondCalls = await second.callCount
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 0, "A source after one that set every value must not be asked")
        XCTAssertEqual(keys, MediaSortKeys(dateAdded: added, dateTaken: taken, subtype: .screenshot, source: .encryptedMetadata))
    }

    func testResolverFillsMissingDatesFromLaterSources() async {
        let first = StubSortKeySource(MediaSortKeys(dateAdded: nil, dateTaken: nil,
                                                    subtype: .screenshot, source: .encryptedMetadata))
        let second = StubSortKeySource(MediaSortKeys(recordCreatedAt: recordCreatedAt, componentType: .photo))
        let keys = await MediaSortKeyResolver(sources: [first, second]).sortKeys(for: request())
        XCTAssertEqual(keys.dateAdded, recordCreatedAt)
        XCTAssertEqual(keys.dateTaken, recordCreatedAt)
        XCTAssertEqual(keys.subtype, .screenshot, "The subtype comes from the first source that has one")
        XCTAssertEqual(keys.source, .recordFields, "The source names the source that supplied dateAdded")
    }

    func testDateTakenFallsBackToDateAddedBeforeRecordCreatedAt() async throws {
        let url = try await encryptedPhoto(captureDate: nil, encryptionDate: added)
        let keys = await MediaSortKeyResolver.standard(keyBytes: key.keyBytes)
            .sortKeys(for: request(fileURL: url, record: descriptor(createdAt: recordCreatedAt)))
        XCTAssertEqual(keys.dateAdded, added)
        XCTAssertEqual(keys.dateTaken, added)
        XCTAssertEqual(keys.source, .encryptedMetadata)
    }

    func testResolverFallsThroughNilSourcesInOrder() async {
        let empty = StubSortKeySource(nil)
        let alsoEmpty = StubSortKeySource(nil)
        let answering = StubSortKeySource(MediaSortKeys(fileCreationDate: added, componentType: .video))
        let notReached = StubSortKeySource(MediaSortKeys(recordCreatedAt: recordCreatedAt, componentType: .photo))
        let keys = await MediaSortKeyResolver(sources: [empty, alsoEmpty, answering, notReached])
            .sortKeys(for: request(type: .video))
        let calls = [await empty.callCount, await alsoEmpty.callCount, await answering.callCount, await notReached.callCount]
        XCTAssertEqual(calls, [1, 1, 1, 0])
        XCTAssertEqual(keys, MediaSortKeys(fileCreationDate: added, componentType: .video))
    }

    func testResolverWithNoAnswersUsesComponentType() async {
        let none = await MediaSortKeyResolver(sources: []).sortKeys(for: request(type: .video))
        XCTAssertNil(none.dateAdded)
        XCTAssertNil(none.dateTaken)
        XCTAssertEqual(none.subtype, .video)

        let nilAnswers = await MediaSortKeyResolver(sources: [StubSortKeySource(nil)]).sortKeys(for: request(type: .photo))
        XCTAssertNil(nilAnswers.dateAdded)
        XCTAssertNil(nilAnswers.dateTaken)
        XCTAssertEqual(nilAnswers.subtype, .stillImage)
    }

    func testFileWithUndatedMetadataSortsByTheRecordsCreatedAt() async throws {
        let url = try await encryptedPhoto(captureDate: nil, encryptionDate: nil, isScreenshot: true)
        let keys = await MediaSortKeyResolver.standard(keyBytes: key.keyBytes)
            .sortKeys(for: request(fileURL: url, record: descriptor(createdAt: recordCreatedAt)))
        XCTAssertEqual(keys.dateAdded, recordCreatedAt)
        XCTAssertEqual(keys.dateTaken, recordCreatedAt)
        XCTAssertEqual(keys.subtype, .screenshot, "The undated metadata still supplies the subtype")
        XCTAssertEqual(keys.source, .recordFields)
    }

    func testFileWithUndatedMetadataAndNoRecordSortsByItsCreationDate() async throws {
        let url = try await encryptedPhoto(captureDate: nil, encryptionDate: nil)
        let creationDate = try XCTUnwrap(url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let keys = await MediaSortKeyResolver.standard(keyBytes: key.keyBytes).sortKeys(for: request(fileURL: url))
        XCTAssertEqual(keys.dateAdded, creationDate)
        XCTAssertEqual(keys.dateTaken, creationDate)
        XCTAssertEqual(keys.source, .fileAttributes)
    }

    // MARK: - Builders

    /// A move back to the device indexes the landed file from its own metadata,
    /// not from the date its plan recorded.
    func testMovedFileIndexEntryComesFromTheFileNotThePlan() async throws {
        let url = try await encryptedPhoto(captureDate: taken, encryptionDate: added)
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo,
                                 createdAt: Date(timeIntervalSince1970: 0), sizeBytes: 1)
        let entry = await DiskMediaBackend.indexEntry(forMovedFileAt: url, item: item, key: key)
        XCTAssertEqual(entry.dateEncrypted, added)
        XCTAssertEqual(entry.dateTaken, taken)
        XCTAssertEqual(entry.subtypeRawValue, MediaFilterOptions.stillImage.rawValue)
    }

    func testMovedFileWithUndatedMetadataTakesThePlansDate() async throws {
        let url = try await encryptedPhoto(captureDate: nil, encryptionDate: nil, isScreenshot: true)
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo,
                                 createdAt: recordCreatedAt, sizeBytes: 1)
        let entry = await DiskMediaBackend.indexEntry(forMovedFileAt: url, item: item, key: key)
        XCTAssertEqual(entry.dateEncrypted, recordCreatedAt)
        XCTAssertEqual(entry.dateTaken, recordCreatedAt)
        XCTAssertEqual(entry.subtypeRawValue, MediaFilterOptions.screenshot.rawValue)
    }

    func testRecordSortKeysOfUndatedMetadataTakeThePlansDate() async throws {
        let url = try await encryptedPhoto(captureDate: nil, encryptionDate: nil)
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo,
                                 createdAt: recordCreatedAt, sizeBytes: 1)
        let keys = await LocalToCloudKitStep.recordSortKeys(for: item, at: url, keyBytes: key.keyBytes)
        XCTAssertEqual(keys.dateAdded, recordCreatedAt)
        XCTAssertEqual(keys.dateTaken, recordCreatedAt)
    }

    // MARK: - Sources

    func testFileSourceReadsDatesAndScreenshotFromAnENC2File() async throws {
        let url = try await encryptedPhoto(captureDate: taken, encryptionDate: added, isScreenshot: true)
        let keys = await FileMetadataSortKeySource(keyBytes: key.keyBytes).sortKeys(for: request(fileURL: url))
        XCTAssertEqual(keys, MediaSortKeys(dateAdded: added, dateTaken: taken, subtype: .screenshot, source: .encryptedMetadata))
    }

    func testFileSourceReturnsNilForV1File() async throws {
        let url = tempDirectory.appendingPathComponent("v1.\(MediaType.photo.encryptedFileExtension)")
        try Data(repeating: 7, count: 64).write(to: url)
        let keys = await FileMetadataSortKeySource(keyBytes: key.keyBytes).sortKeys(for: request(fileURL: url))
        XCTAssertNil(keys)
    }

    func testRecordFieldsSourceUsesCreatedAtForBothDatesWithoutAddedAt() async {
        let keys = await CloudKitRecordFieldsSortKeySource()
            .sortKeys(for: request(type: .video, record: descriptor(type: .video, createdAt: recordCreatedAt)))
        XCTAssertEqual(keys, MediaSortKeys(dateAdded: recordCreatedAt, dateTaken: recordCreatedAt,
                                           subtype: .video, source: .recordFields))
        let noRecord = await CloudKitRecordFieldsSortKeySource().sortKeys(for: request())
        XCTAssertNil(noRecord)
    }
}
