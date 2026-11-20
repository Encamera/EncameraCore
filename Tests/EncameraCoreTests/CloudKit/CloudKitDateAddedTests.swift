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

    private func descriptor(id: String, type: MediaType = .photo, createdAt: Date) -> CloudKitMediaRecordDescriptor {
        CloudKitMediaRecordDescriptor(albumID: "album", mediaID: id, mediaType: type,
                                      createdAt: createdAt, sizeBytes: 1, keyFingerprint: "")
    }

    private func meta(_ descriptor: CloudKitMediaRecordDescriptor) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(descriptor: descriptor, creationDeviceID: "device", schemaVersion: 1, recordChangeTag: nil)
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
}
