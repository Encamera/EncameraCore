//
//  CloudKitDateAddedTests.swift
//  EncameraCoreTests
//
//  How a CloudKit album's index entries get their "Date Added", "Date Taken"
//  and subtype: from a record, through a merge, and across a move in either
//  direction. A record carries one date, `createdAt`: when the media was taken,
//  falling back to when it was added.
//

import XCTest
@testable import EncameraCore

final class CloudKitDateAddedTests: XCTestCase {

    private let taken = Date(timeIntervalSince1970: 1_500_000_000)
    private let added = Date(timeIntervalSince1970: 1_700_000_000)
    private let key = PrivateKey(keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitDateAddedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func descriptor(id: String, type: MediaType = .photo, createdAt: Date) -> CloudKitMediaRecordDescriptor {
        CloudKitMediaRecordDescriptor(albumID: "album", mediaID: id, mediaType: type,
                                      createdAt: createdAt, sizeBytes: 1, keyFingerprint: "")
    }

    private func meta(_ descriptor: CloudKitMediaRecordDescriptor) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(descriptor: descriptor, creationDeviceID: "device", schemaVersion: 1, recordChangeTag: nil)
    }

    /// An ENC2 photo whose embedded metadata carries the given dates.
    private func encryptedPhoto(id: String, captureDate: Date?, encryptionDate: Date?) async throws -> URL {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = captureDate
        metadata.encryptionDate = encryptionDate
        let source = CleartextMedia(source: Data((0..<4096).map { UInt8($0 % 251) }), mediaType: .photo, id: id)
        let url = tempDirectory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")
        _ = try await SecretFileHandlerV2(keyBytes: key.keyBytes, source: source, targetURL: url)
            .encryptWithMetadata(metadata)
        return url
    }

    // MARK: - Record -> index

    func testIndexEntryTakesBothDatesFromCreatedAt() {
        let entry = CloudKitSyncCoordinator.indexEntry(from: meta(descriptor(id: "a", createdAt: taken)))
        XCTAssertEqual(entry.dateEncrypted, taken)
        XCTAssertEqual(entry.dateTaken, taken)
    }

    func testIndexEntrySubtypeFollowsComponentType() {
        let video = CloudKitSyncCoordinator.indexEntry(from: meta(descriptor(id: "v", type: .video, createdAt: taken)))
        let photo = CloudKitSyncCoordinator.indexEntry(from: meta(descriptor(id: "p", type: .photo, createdAt: taken)))
        XCTAssertEqual(video.subtypeRawValue, MediaFilterOptions.video.rawValue)
        XCTAssertEqual(photo.subtypeRawValue, MediaFilterOptions.stillImage.rawValue)
        let index = MediaIndex(entries: [video, photo])
        XCTAssertEqual(index.sortedFilteredEntries(sortBy: .dateEncrypted(ascending: true), filterBy: .video).map(\.id), ["v"],
                       "A video filter must not match CloudKit stills")
    }

    // MARK: - Merge

    func testMergeFillsAnUnknownSubtype() {
        let legacy = MediaIndexEntry(id: "a", hasPhotoComponent: true, hasVideoComponent: false,
                                     dateEncrypted: added, dateTaken: taken, subtypeRawValue: 0)
        let fresh = MediaIndexEntry(id: "a", hasPhotoComponent: true, hasVideoComponent: false,
                                    dateEncrypted: added, dateTaken: taken,
                                    subtypeRawValue: MediaFilterOptions.stillImage.rawValue)
        XCTAssertEqual(legacy.merged(with: fresh).subtypeRawValue, MediaFilterOptions.stillImage.rawValue)
    }

    func testLivePhotoWhoseVideoArrivesFirstMergesToAStill() {
        let video = CloudKitSyncCoordinator.indexEntry(from: meta(descriptor(id: "live", type: .video, createdAt: taken)))
        let photo = CloudKitSyncCoordinator.indexEntry(from: meta(descriptor(id: "live", type: .photo, createdAt: taken)))
        let merged = video.merged(with: photo)
        XCTAssertTrue(merged.hasPhotoComponent && merged.hasVideoComponent)
        XCTAssertEqual(merged.subtypeRawValue, MediaFilterOptions.stillImage.rawValue)
    }

    // MARK: - Moves

    /// A move to CloudKit dates the record from the file itself, whatever the
    /// plan recorded: an item move plans with the file's creation date.
    func testMigratedRecordDateComesFromTheFilesMetadata() async throws {
        let url = try await encryptedPhoto(id: "a", captureDate: taken, encryptionDate: added)
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo,
                                 createdAt: Date(timeIntervalSince1970: 0), sizeBytes: 1)
        let createdAt = await LocalToCloudKitStep.recordSortKeys(for: item, at: url, keyBytes: key.keyBytes).dateTaken
        XCTAssertEqual(createdAt, taken)
    }

    func testMigratedRecordOfAFileWithNoCaptureDateIsTakenWhenAdded() async throws {
        let url = try await encryptedPhoto(id: "a", captureDate: nil, encryptionDate: added)
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: taken, sizeBytes: 1)
        let createdAt = await LocalToCloudKitStep.recordSortKeys(for: item, at: url, keyBytes: key.keyBytes).dateTaken
        XCTAssertEqual(createdAt, added)
    }

    func testMigratedRecordFallsBackToThePlanWhenTheFileHasNoMetadata() async throws {
        let url = tempDirectory.appendingPathComponent("v1.encimage")
        try Data(repeating: 7, count: 64).write(to: url)
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: taken, sizeBytes: 1)
        let createdAt = await LocalToCloudKitStep.recordSortKeys(for: item, at: url, keyBytes: key.keyBytes).dateTaken
        XCTAssertEqual(createdAt, taken)
    }

    func testFileMovedToLocalFallsBackToTheItemsDateWhenUnreadable() async {
        let item = MigrationItem(mediaID: "a", recordName: "a#0", mediaType: .photo, createdAt: taken, sizeBytes: 1)
        let entry = await DiskMediaBackend.indexEntry(forMovedFileAt: tempDirectory.appendingPathComponent("missing"),
                                                      item: item, key: key)
        XCTAssertEqual(entry.dateEncrypted, taken)
        XCTAssertEqual(entry.dateTaken, taken)
        XCTAssertEqual(entry.subtypeRawValue, MediaFilterOptions.stillImage.rawValue)
    }
}
