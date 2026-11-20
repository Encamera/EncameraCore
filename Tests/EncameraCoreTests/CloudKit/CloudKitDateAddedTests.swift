//
//  CloudKitDateAddedTests.swift
//  EncameraCoreTests
//
//  How a CloudKit album's index entries get their "Date Added", "Date Taken"
//  and subtype: from a record, through a merge, and across a move in either
//  direction. A record's sealed `encMetadata` carries both dates; without it the
//  record has one date, `createdAt`: when the media was taken, falling back to
//  when it was added.
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

    private func descriptor(id: String, type: MediaType = .photo, createdAt: Date,
                            encMetadata: EncryptedFileMetadata? = nil) throws -> CloudKitMediaRecordDescriptor {
        let recordName = MediaRecordName.componentRecordName(mediaID: id, type: type)
        let sealed = try encMetadata.map { try CloudKitRecordMetadataHandler.encryptMetadata($0, recordName: recordName, keyBytes: key.keyBytes) }
        return CloudKitMediaRecordDescriptor(albumID: "album", mediaID: id, recordName: recordName, mediaType: type,
                                             createdAt: createdAt, sizeBytes: 1, keyFingerprint: "", encMetadata: sealed)
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

    func testIndexEntryTakesBothDatesFromCreatedAt() async throws {
        let entry = await CloudKitSyncCoordinator.indexEntry(from: meta(try descriptor(id: "a", createdAt: taken)),
                                                             keyBytes: key.keyBytes)
        XCTAssertEqual(entry.dateEncrypted, taken)
        XCTAssertEqual(entry.dateTaken, taken)
    }

    func testIndexEntrySubtypeFollowsComponentType() async throws {
        let video = await CloudKitSyncCoordinator.indexEntry(from: meta(try descriptor(id: "v", type: .video, createdAt: taken)),
                                                             keyBytes: key.keyBytes)
        let photo = await CloudKitSyncCoordinator.indexEntry(from: meta(try descriptor(id: "p", type: .photo, createdAt: taken)),
                                                             keyBytes: key.keyBytes)
        XCTAssertEqual(video.subtypeRawValue, MediaFilterOptions.video.rawValue)
        XCTAssertEqual(photo.subtypeRawValue, MediaFilterOptions.stillImage.rawValue)
        let index = MediaIndex(entries: [video, photo])
        XCTAssertEqual(index.sortedFilteredEntries(sortBy: .dateAdded(ascending: true), filterBy: .video).map(\.id), ["v"],
                       "A video filter must not match CloudKit stills")
    }

    /// The reported bug: a capture made before an import of an older photo sorted
    /// after it under "Date Added, oldest first", because both records were dated
    /// by `createdAt`, the capture date.
    func testDateAddedSortsAnImportOfAnOlderPhotoAfterAnEarlierCapture() async throws {
        let captureTime = Date(timeIntervalSince1970: 1_800_000_000)
        let importTime = captureTime.addingTimeInterval(60)
        var captureMetadata = EncryptedFileMetadata()
        captureMetadata.captureDate = captureTime
        captureMetadata.encryptionDate = captureTime
        var importMetadata = EncryptedFileMetadata()
        importMetadata.captureDate = taken
        importMetadata.encryptionDate = importTime
        let capture = try descriptor(id: "capture", createdAt: captureTime, encMetadata: captureMetadata)
        let importedOldPhoto = try descriptor(id: "import", createdAt: taken, encMetadata: importMetadata)

        var entries: [MediaIndexEntry] = []
        for record in [importedOldPhoto, capture] {
            entries.append(await CloudKitSyncCoordinator.indexEntry(from: meta(record), keyBytes: key.keyBytes))
        }
        let index = MediaIndex(entries: entries)

        XCTAssertEqual(index.sortedFilteredEntries(sortBy: .dateAdded(ascending: true), filterBy: .all).map(\.id),
                       ["capture", "import"])
        XCTAssertEqual(index.sortedFilteredEntries(sortBy: .dateTaken(ascending: true), filterBy: .all).map(\.id),
                       ["import", "capture"])
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

    func testLivePhotoWhoseVideoArrivesFirstMergesToAStill() async throws {
        let video = await CloudKitSyncCoordinator.indexEntry(from: meta(try descriptor(id: "live", type: .video, createdAt: taken)),
                                                             keyBytes: key.keyBytes)
        let photo = await CloudKitSyncCoordinator.indexEntry(from: meta(try descriptor(id: "live", type: .photo, createdAt: taken)),
                                                             keyBytes: key.keyBytes)
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
