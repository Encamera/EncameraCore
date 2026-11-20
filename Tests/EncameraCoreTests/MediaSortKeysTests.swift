//
//  MediaSortKeysTests.swift
//  EncameraCoreTests
//
//  The sort keys read from a file's encrypted metadata, and the one comparator
//  both the disk enumeration and index paging order media with.
//

import XCTest
@testable import EncameraCore

final class MediaSortKeysTests: XCTestCase {

    private let taken = Date(timeIntervalSince1970: 1_500_000_000)
    private let added = Date(timeIntervalSince1970: 1_700_000_000)
    private let laterAdded = Date(timeIntervalSince1970: 1_800_000_000)

    private func metadata(captureDate: Date? = nil,
                          encryptionDate: Date? = nil,
                          originalMediaType: String? = nil,
                          isLivePhoto: Bool? = nil,
                          isScreenshot: Bool? = nil) -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = captureDate
        metadata.encryptionDate = encryptionDate
        metadata.originalMediaType = originalMediaType
        if isLivePhoto != nil || isScreenshot != nil {
            metadata.contentAnalysis = .init(isScreenshot: isScreenshot, isLivePhoto: isLivePhoto)
        }
        return metadata
    }

    private func keys(added: Date?, taken: Date?) -> MediaSortKeys {
        MediaSortKeys(dateAdded: added, dateTaken: taken, subtype: .stillImage, source: .encryptedMetadata)
    }

    private func sortedIDs(_ items: [(id: String, keys: MediaSortKeys)], by option: MediaSortOption) -> [String] {
        items.sorted { MediaSorter.isOrderedBefore($0, $1, by: option) }.map(\.id)
    }

    // MARK: - Keys from encrypted metadata

    func testMetadataKeysUseEncryptionDateForAddedAndCaptureDateForTaken() {
        let keys = MediaSortKeys(metadata: metadata(captureDate: taken, encryptionDate: added), componentType: .photo)
        XCTAssertEqual(keys.dateAdded, added)
        XCTAssertEqual(keys.dateTaken, taken)
        XCTAssertEqual(keys.source, .encryptedMetadata)
    }

    func testMissingCaptureDateFallsBackToDateAdded() {
        let keys = MediaSortKeys(metadata: metadata(encryptionDate: added), componentType: .photo)
        XCTAssertEqual(keys.dateAdded, added)
        XCTAssertEqual(keys.dateTaken, added)
    }

    func testSubtypeRulesMatchLivePhotoVideoScreenshotStill() {
        let cases: [(name: String, metadata: EncryptedFileMetadata, componentType: MediaType, expected: MediaFilterOptions)] = [
            ("Live Photo flagged by content analysis", metadata(originalMediaType: "video", isLivePhoto: true), .video, .stillImage),
            ("Live Photo flagged by original type", metadata(originalMediaType: "livePhoto"), .video, .stillImage),
            ("video", metadata(originalMediaType: "video"), .video, .video),
            ("screenshot", metadata(originalMediaType: "photo", isScreenshot: true), .photo, .screenshot),
            ("still", metadata(originalMediaType: "photo"), .photo, .stillImage),
            ("no type recorded", metadata(), .photo, .stillImage),
        ]
        for testCase in cases {
            let keys = MediaSortKeys(metadata: testCase.metadata, componentType: testCase.componentType)
            XCTAssertEqual(keys.subtype, testCase.expected, testCase.name)
        }
    }

    // MARK: - Sorter

    func testSorterPutsUnknownDatesLastInBothDirections() {
        let items: [(id: String, keys: MediaSortKeys)] = [
            ("unknown", keys(added: nil, taken: nil)),
            ("old", keys(added: added, taken: taken)),
            ("new", keys(added: laterAdded, taken: added)),
        ]
        XCTAssertEqual(sortedIDs(items, by: .dateAdded(ascending: true)), ["old", "new", "unknown"])
        XCTAssertEqual(sortedIDs(items, by: .dateAdded(ascending: false)), ["new", "old", "unknown"])
        XCTAssertEqual(sortedIDs(items, by: .dateTaken(ascending: true)), ["old", "new", "unknown"])
        XCTAssertEqual(sortedIDs(items, by: .dateTaken(ascending: false)), ["new", "old", "unknown"])
    }

    func testSorterBreaksDateTiesByIDForStablePaging() {
        let items: [(id: String, keys: MediaSortKeys)] = [
            ("c", keys(added: added, taken: taken)),
            ("a", keys(added: added, taken: taken)),
            ("b", keys(added: added, taken: taken)),
            ("z", keys(added: nil, taken: nil)),
            ("y", keys(added: nil, taken: nil)),
        ]
        for option: MediaSortOption in [.dateTaken(ascending: true), .dateTaken(ascending: false),
                                         .dateAdded(ascending: true), .dateAdded(ascending: false)] {
            XCTAssertEqual(sortedIDs(items, by: option), ["a", "b", "c", "y", "z"], option.rawValue)
            XCTAssertEqual(sortedIDs(items.reversed(), by: option), ["a", "b", "c", "y", "z"], option.rawValue)
        }
    }

    // MARK: - Disk enumeration and index paging agree

    /// "b" and "a" share a capture date but were added at different times; "c"
    /// has no metadata and no readable file, so both its dates are unknown.
    func testNonIndexEnumerationAndIndexPagingProduceTheSameOrder() async {
        let directory = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        func photo(_ id: String) -> EncryptedMedia {
            EncryptedMedia(source: .url(directory.appendingPathComponent("\(id).\(MediaType.photo.encryptedFileExtension)")),
                           mediaType: .photo, id: id)
        }
        let media = [photo("c"), photo("b"), photo("a")]
        var metadataMap: [URL: EncryptedFileMetadata] = [:]
        if case .url(let url) = media[1].source {
            metadataMap[url] = metadata(captureDate: taken, encryptionDate: laterAdded, originalMediaType: "photo")
        }
        if case .url(let url) = media[2].source {
            metadataMap[url] = metadata(captureDate: taken, encryptionDate: added, originalMediaType: "photo")
        }

        let fileAccess = DiskFileAccess(key: PrivateKey(keyBytes: Array(repeating: 0x42, count: 32),
                                                        creationDate: Date(timeIntervalSince1970: 0)))
        let options: [(option: MediaSortOption, expected: [String])] = [
            (.dateTaken(ascending: true), ["a", "b", "c"]),
            (.dateTaken(ascending: false), ["a", "b", "c"]),
            (.dateAdded(ascending: true), ["a", "b", "c"]),
            (.dateAdded(ascending: false), ["b", "a", "c"]),
        ]
        for (option, expected) in options {
            let enumerated = await fileAccess.buildMediaWithMetadataArray(
                media: media, metadataMap: metadataMap, sortOption: option, filterOptions: .all
            )
            let index = MediaIndex(entries: DiskMediaBackend.makeEntries(fromFileLevelMetadata: enumerated.reversed()))
            let paged = index.sortedFilteredEntries(sortBy: option, filterBy: .all)

            XCTAssertEqual(enumerated.map(\.media.id), expected, option.rawValue)
            XCTAssertEqual(paged.map(\.id), enumerated.map(\.media.id), option.rawValue)
        }
    }
}
