//
//  IndexBackendEquivalenceTests.swift
//  EncameraCoreTests
//
//  The payoff of centralizing the reconcile algebra: the disk and CloudKit
//  backends must build the *same* index shape for the same logical media. Each
//  backend keeps its own source-specific mapping (disk reads file metadata,
//  cloud reads CloudKit component records), but both feed the shared `upsert`
//  algebra — so id grouping and the photo/video component flags must come out
//  identical. This test feeds one logical media set through both mapping → upsert
//  sequences and asserts the structural fields match, guarding the drift the old
//  duplicated logic allowed.
//
//  A second case compares whole entries, dates and subtype included, for media
//  taken long before it was added, screenshots among them: the disk reads each
//  file's encrypted metadata, and the cloud the same metadata sealed in each
//  record's `encMetadata`.
//

import XCTest
@testable import EncameraCore

final class IndexBackendEquivalenceTests: XCTestCase {

    /// The structural shape the shared algebra is responsible for: which ids
    /// exist and which component flags each carries. Sorted for order-independent
    /// comparison.
    private struct Shape: Equatable, CustomStringConvertible {
        let rows: [String: [Bool]]   // id -> [hasPhoto, hasVideo]
        init(_ entries: [MediaIndexEntry]) {
            rows = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, [$0.hasPhotoComponent, $0.hasVideoComponent])
            })
        }
        var description: String { rows.sorted { $0.key < $1.key }.description }
    }

    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func diskItem(id: String, type: MediaType, subtype: MediaFilterOptions) -> MediaWithMetadata<EncryptedMedia> {
        MediaWithMetadata(
            media: EncryptedMedia(source: URL(fileURLWithPath: "/tmp/\(id).enc"), mediaType: type, id: id),
            metadata: nil,
            dateTaken: date,
            dateEncrypted: date,
            mediaSubtype: subtype
        )
    }

    private let key = PrivateKey(keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    private func cloudMeta(id: String, type: MediaType, metadata: EncryptedFileMetadata? = nil) throws -> CloudKitMediaMetadata {
        let recordName = "\(id)#\(type.rawValue)"
        return CloudKitMediaMetadata(
            recordName: recordName,
            albumID: "album",
            mediaID: id,
            mediaType: type,
            createdAt: metadata?.captureDate ?? date,
            sizeBytes: 0,
            creationDeviceID: "device",
            schemaVersion: 1,
            keyFingerprint: "",
            recordChangeTag: nil,
            encMetadata: try metadata.map { try CloudKitRecordMetadataHandler.encryptMetadata($0, recordName: recordName, keyBytes: key.keyBytes) }
        )
    }

    /// Metadata of media taken a year before it was added.
    private func metadata(originalMediaType: String, isScreenshot: Bool = false, isLivePhoto: Bool = false) -> EncryptedFileMetadata {
        var metadata = EncryptedFileMetadata()
        metadata.captureDate = date
        metadata.encryptionDate = date.addingTimeInterval(365 * 24 * 3600)
        metadata.originalMediaType = originalMediaType
        metadata.contentAnalysis = .init(isScreenshot: isScreenshot, isLivePhoto: isLivePhoto)
        return metadata
    }

    /// Same media, same full entries: dates, subtype and component flags.
    func testDiskAndCloudProduceIdenticalEntriesIncludingDatesAndSubtype() async throws {
        let components: [(id: String, type: MediaType, metadata: EncryptedFileMetadata)] = [
            ("live", .video, metadata(originalMediaType: "livePhoto", isLivePhoto: true)),
            ("live", .photo, metadata(originalMediaType: "livePhoto", isLivePhoto: true)),
            ("video", .video, metadata(originalMediaType: "video")),
            ("still", .photo, metadata(originalMediaType: "photo")),
            ("screenshot", .photo, metadata(originalMediaType: "photo", isScreenshot: true)),
        ]

        var diskMedia: [EncryptedMedia] = []
        var metadataMap: [URL: EncryptedFileMetadata] = [:]
        for component in components {
            let url = URL(fileURLWithPath: "/nonexistent/\(component.id).\(component.type.encryptedFileExtension)")
            diskMedia.append(EncryptedMedia(source: .url(url), mediaType: component.type, id: component.id))
            metadataMap[url] = component.metadata
        }
        let diskItems = await DiskFileAccess(key: key).buildMediaWithMetadataArray(
            media: diskMedia, metadataMap: metadataMap, sortOption: .dateAdded(ascending: true), filterOptions: .all
        )
        var diskIndex: [MediaIndexEntry] = []
        for item in diskItems {
            diskIndex.upsert(DiskMediaBackend.entry(forFileLevelMetadata: item))
        }
        // The Live Photo's video arrives first, which must not make it filter as a video.
        var cloudIndex: [MediaIndexEntry] = []
        for component in components {
            let meta = try cloudMeta(id: component.id, type: component.type, metadata: component.metadata)
            cloudIndex.upsert(await CloudKitSyncCoordinator.indexEntry(from: meta, keyBytes: key.keyBytes))
        }

        let byID = { (entries: [MediaIndexEntry]) in Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }) }
        XCTAssertEqual(byID(cloudIndex), byID(diskIndex))
        let screenshot = byID(cloudIndex)["screenshot"]
        XCTAssertEqual(screenshot?.subtypeRawValue, MediaFilterOptions.screenshot.rawValue)
        XCTAssertNotEqual(screenshot?.dateEncrypted, screenshot?.dateTaken, "the dates must differ to be told apart")
    }

    /// Feed a Live Photo (photo + video components sharing an id) and a video-only
    /// item through both backends' mapping → upsert sequences; the resulting index
    /// shapes must be equal.
    func testDiskAndCloudProduceEquivalentIndexForSameMedia() async throws {
        let livePhotoID = "live-photo-1"
        let videoID = "video-1"

        var diskIndex: [MediaIndexEntry] = []
        for item in [
            diskItem(id: livePhotoID, type: .photo, subtype: .stillImage),
            diskItem(id: livePhotoID, type: .video, subtype: .stillImage),
            diskItem(id: videoID, type: .video, subtype: .video)
        ] {
            diskIndex.upsert(DiskMediaBackend.entry(forFileLevelMetadata: item))
        }

        var cloudIndex: [MediaIndexEntry] = []
        for meta in [
            try cloudMeta(id: livePhotoID, type: .photo),
            try cloudMeta(id: livePhotoID, type: .video),
            try cloudMeta(id: videoID, type: .video)
        ] {
            cloudIndex.upsert(await CloudKitSyncCoordinator.indexEntry(from: meta, keyBytes: nil))
        }

        XCTAssertEqual(
            Shape(diskIndex), Shape(cloudIndex),
            "disk and cloud must produce the same id grouping and component flags for the same media"
        )

        XCTAssertEqual(diskIndex.count, 2, "the two live-photo components collapse into one entry")
        let livePhoto = diskIndex.first { $0.id == livePhotoID }
        XCTAssertEqual([livePhoto?.hasPhotoComponent, livePhoto?.hasVideoComponent], [true, true])
        let video = diskIndex.first { $0.id == videoID }
        XCTAssertEqual([video?.hasPhotoComponent, video?.hasVideoComponent], [false, true])
    }
}
