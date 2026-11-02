//
//  MediaIndexCodecV2Tests.swift
//  EncameraCoreTests
//
//  The media index format records where each component of an entry lives
//  (CloudKit or iCloud Drive). The golden files in `CloudKit/Fixtures` were
//  written by a reference encoder built from the layout documented on
//  `MediaIndexCodec`, not by the codec itself. Never regenerate them from the
//  Swift code: if a test here fails, the code changed the format.
//

import XCTest
@testable import EncameraCore

final class MediaIndexCodecV2Tests: XCTestCase {

    // MARK: - Fixtures

    /// The committed fixture as shipped in the test bundle. The app-hosted Xcode
    /// target flattens it to the bundle root; `swift test` processes it into the
    /// test target's `Bundle.module`.
    private func goldenBytes(_ name: String) throws -> Data {
        let testBundle = Bundle(for: Self.self)
        let candidates = [
            testBundle.url(forResource: name, withExtension: "eix"),
            testBundle.url(forResource: name, withExtension: "eix", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: "eix")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "Missing fixture \(name).eix in the test bundle")
        return try Data(contentsOf: url)
    }

    private static func date(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: interval)
    }

    /// The entries `media-index-v1.eix` was written from.
    private static let v1Entries = [
        MediaIndexEntry(id: "v1-photo", hasPhotoComponent: true, hasVideoComponent: false,
                        dateEncrypted: date(700_000_000.5), dateTaken: date(650_000_000),
                        subtypeRawValue: MediaFilterOptions.stillImage.rawValue),
        MediaIndexEntry(id: "v1-video", hasPhotoComponent: false, hasVideoComponent: true,
                        dateEncrypted: date(700_000_100.25), dateTaken: nil,
                        subtypeRawValue: MediaFilterOptions.video.rawValue),
        MediaIndexEntry(id: "v1-live", hasPhotoComponent: true, hasVideoComponent: true,
                        dateEncrypted: nil, dateTaken: nil,
                        subtypeRawValue: MediaFilterOptions.livePhoto.rawValue)
    ]

    /// The entries `media-index-v2.eix` was written from.
    private static let v2Entries = [
        MediaIndexEntry(id: "v2-live-mixed", hasPhotoComponent: true, hasVideoComponent: true,
                        dateEncrypted: date(710_000_000.5), dateTaken: date(690_000_000),
                        subtypeRawValue: MediaFilterOptions.livePhoto.rawValue,
                        photoLocation: .cloudKit, videoLocation: .iCloudDrive),
        MediaIndexEntry(id: "v2-photo-drive", hasPhotoComponent: true, hasVideoComponent: false,
                        dateEncrypted: date(710_000_100), dateTaken: nil,
                        subtypeRawValue: MediaFilterOptions.screenshot.rawValue,
                        photoLocation: .iCloudDrive),
        MediaIndexEntry(id: "v2-video-ck", hasPhotoComponent: false, hasVideoComponent: true,
                        dateEncrypted: nil, dateTaken: nil,
                        subtypeRawValue: MediaFilterOptions.video.rawValue,
                        videoLocation: .cloudKit),
        MediaIndexEntry(id: "v2-live-drive", hasPhotoComponent: true, hasVideoComponent: true,
                        dateEncrypted: date(710_000_200.75), dateTaken: date(710_000_200.75),
                        subtypeRawValue: MediaFilterOptions.livePhoto.rawValue,
                        photoLocation: .iCloudDrive, videoLocation: .iCloudDrive)
    ]

    private func makeTempIndexURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaIndexCodecV2Tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("index.encindex")
    }

    private func randomKey() -> [UInt8] {
        (0..<32).map { _ in UInt8.random(in: 0...255) }
    }

    private func mixedLivePhoto(id: String = "live") -> MediaIndexEntry {
        MediaIndexEntry(id: id, hasPhotoComponent: true, hasVideoComponent: true,
                        dateEncrypted: Self.date(720_000_000), dateTaken: Self.date(719_000_000),
                        subtypeRawValue: MediaFilterOptions.livePhoto.rawValue,
                        photoLocation: .cloudKit, videoLocation: .iCloudDrive)
    }

    // MARK: - Golden vectors

    func testV1IndexDecodesAsAllCloudKit() async throws {
        let v1 = try goldenBytes("media-index-v1")
        XCTAssertEqual(Array(v1[4..<6]), [1, 0], "the fixture is a version 1 index")

        let decoded = try MediaIndexCodec.decode(v1)
        XCTAssertEqual(decoded, Self.v1Entries)
        for entry in decoded {
            XCTAssertEqual(entry.photoLocation, .cloudKit, entry.id)
            XCTAssertEqual(entry.videoLocation, .cloudKit, entry.id)
        }

        // The same bytes, encrypted on disk as a store writes them, load unchanged.
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        try MediaIndexStore.encrypt(v1, keyBytes: key).write(to: indexURL)
        let loaded = await MediaIndexStore(keyBytes: key, indexURL: indexURL).load()
        XCTAssertEqual(loaded?.entries, Self.v1Entries)
    }

    func testV2GoldenVectorDecodes() throws {
        let v2 = try goldenBytes("media-index-v2")
        XCTAssertEqual(Array(v2[4..<6]), [2, 0], "the fixture is a version 2 index")

        let decoded = try MediaIndexCodec.decode(v2)
        XCTAssertEqual(decoded, Self.v2Entries)
        XCTAssertEqual(decoded.first?.photoLocation, .cloudKit)
        XCTAssertEqual(decoded.first?.videoLocation, .iCloudDrive)
    }

    func testEncodeWritesV2GoldenBytes() throws {
        XCTAssertEqual(MediaIndexCodec.encode(Self.v2Entries), try goldenBytes("media-index-v2"),
                       "the writer emits version 2 exactly as the documented layout describes")
    }

    func testUnknownVersionIsRejected() throws {
        var bytes = try goldenBytes("media-index-v2")
        bytes[4] = 3
        XCTAssertThrowsError(try MediaIndexCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? MediaIndexError, .unsupportedVersion)
        }
    }

    // MARK: - Round trip

    func testMixedLocationLivePhotoRoundTrips() async throws {
        let entry = mixedLivePhoto()
        XCTAssertEqual(try MediaIndexCodec.decode(MediaIndexCodec.encode([entry])), [entry])

        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        try await MediaIndexStore(keyBytes: key, indexURL: indexURL).save(MediaIndex(entries: [entry]))
        let loaded = await MediaIndexStore(keyBytes: key, indexURL: indexURL).load()
        let reloaded = try XCTUnwrap(loaded?.entries.first)
        XCTAssertEqual(reloaded, entry)
        XCTAssertEqual(reloaded.photoLocation, .cloudKit)
        XCTAssertEqual(reloaded.videoLocation, .iCloudDrive)
    }

    func testLocationOfAbsentComponentIsCloudKit() {
        let entry = MediaIndexEntry(id: "photo", hasPhotoComponent: true, hasVideoComponent: false,
                                    dateEncrypted: nil, dateTaken: nil,
                                    subtypeRawValue: MediaFilterOptions.stillImage.rawValue,
                                    photoLocation: .iCloudDrive, videoLocation: .iCloudDrive)
        XCTAssertEqual(entry.photoLocation, .iCloudDrive)
        XCTAssertEqual(entry.videoLocation, .cloudKit, "a component the entry lacks has no location to record")
    }

    // MARK: - Merge and remove

    func testUpsertOfSeparateComponentsKeepsEachLocation() {
        var entries: [MediaIndexEntry] = []
        entries.upsert(MediaIndexEntry(id: "live", hasPhotoComponent: true, hasVideoComponent: false,
                                       dateEncrypted: Self.date(720_000_000), dateTaken: Self.date(719_000_000),
                                       subtypeRawValue: MediaFilterOptions.livePhoto.rawValue,
                                       photoLocation: .cloudKit))
        entries.upsert(MediaIndexEntry(id: "live", hasPhotoComponent: false, hasVideoComponent: true,
                                       dateEncrypted: nil, dateTaken: nil,
                                       subtypeRawValue: MediaFilterOptions.video.rawValue,
                                       videoLocation: .iCloudDrive))
        XCTAssertEqual(entries, [mixedLivePhoto()])
    }

    func testMergeTakesIncomingComponentLocation() {
        var entries = [mixedLivePhoto()]
        let changed = entries.upsert(MediaIndexEntry(id: "live", hasPhotoComponent: false, hasVideoComponent: true,
                                                     dateEncrypted: nil, dateTaken: nil,
                                                     subtypeRawValue: MediaFilterOptions.video.rawValue,
                                                     videoLocation: .cloudKit))
        XCTAssertTrue(changed, "a component reported at a new location changes the entry")
        XCTAssertEqual(entries.first?.videoLocation, .cloudKit)
        XCTAssertEqual(entries.first?.photoLocation, .cloudKit, "the photo, not in the incoming entry, is untouched")

        var unchanged = [mixedLivePhoto()]
        XCTAssertFalse(unchanged.upsert(MediaIndexEntry(id: "live", hasPhotoComponent: true, hasVideoComponent: false,
                                                        dateEncrypted: nil, dateTaken: nil,
                                                        subtypeRawValue: MediaFilterOptions.livePhoto.rawValue,
                                                        photoLocation: .cloudKit)),
                       "re-reporting a component at its current location is a no-op")
        XCTAssertEqual(unchanged, [mixedLivePhoto()], "the video half keeps .iCloudDrive")
    }

    func testRemoveComponentKeepsOtherHalfLocation() async throws {
        var withoutPhoto = [mixedLivePhoto()]
        XCTAssertFalse(withoutPhoto.removeComponent(
            recordName: MediaRecordName.componentRecordName(mediaID: "live", type: .photo)))
        XCTAssertEqual(withoutPhoto.first?.hasPhotoComponent, false)
        XCTAssertEqual(withoutPhoto.first?.hasVideoComponent, true)
        XCTAssertEqual(withoutPhoto.first?.videoLocation, .iCloudDrive)

        let photoOnDrive = MediaIndexEntry(id: "live", hasPhotoComponent: true, hasVideoComponent: true,
                                           dateEncrypted: nil, dateTaken: nil,
                                           subtypeRawValue: MediaFilterOptions.livePhoto.rawValue,
                                           photoLocation: .iCloudDrive, videoLocation: .cloudKit)
        var withoutVideo = [photoOnDrive]
        XCTAssertFalse(withoutVideo.removeComponent(
            recordName: MediaRecordName.componentRecordName(mediaID: "live", type: .video)))
        XCTAssertEqual(withoutVideo.first?.hasVideoComponent, false)
        XCTAssertEqual(withoutVideo.first?.photoLocation, .iCloudDrive)

        // Through the store, the surviving half's location persists.
        let key = randomKey()
        let indexURL = try makeTempIndexURL()
        let store = MediaIndexStore(keyBytes: key, indexURL: indexURL)
        try await store.save(MediaIndex(entries: [mixedLivePhoto()]))
        let removedWhole = try await store.removeComponent(
            recordName: MediaRecordName.componentRecordName(mediaID: "live", type: .photo))
        XCTAssertFalse(removedWhole)
        let loaded = await MediaIndexStore(keyBytes: key, indexURL: indexURL).load()
        let survivor = try XCTUnwrap(loaded?.entries.first)
        XCTAssertFalse(survivor.hasPhotoComponent)
        XCTAssertEqual(survivor.videoLocation, .iCloudDrive)
    }
}
