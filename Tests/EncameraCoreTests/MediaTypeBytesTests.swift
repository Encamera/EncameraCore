//
//  MediaTypeBytesTests.swift
//  EncameraCoreTests
//
//  The classification rule every storage walk shares.
//

import XCTest
@testable import EncameraCore

final class MediaTypeBytesTests: XCTestCase {

    func testStillPhotoCountsAsPhoto() {
        let bytes = MediaTypeBytes.tabulate([MediaComponentBytes(filename: "abc.encimage", bytes: 100)])

        XCTAssertEqual(bytes, MediaTypeBytes(photoBytes: 100))
    }

    func testStandaloneVideoCountsAsVideo() {
        let bytes = MediaTypeBytes.tabulate([MediaComponentBytes(filename: "abc.encvideo", bytes: 5_000)])

        XCTAssertEqual(bytes, MediaTypeBytes(videoBytes: 5_000))
    }

    /// The product rule: "Videos" means standalone videos, so a Live Photo's video
    /// track belongs with its photo.
    func testLivePhotoCountsWhollyAsPhoto() {
        let bytes = MediaTypeBytes.tabulate([
            MediaComponentBytes(filename: "live.encimage", bytes: 300),
            MediaComponentBytes(filename: "live.encvideo", bytes: 2_000),
            MediaComponentBytes(filename: "clip.encvideo", bytes: 700),
        ])

        XCTAssertEqual(bytes, MediaTypeBytes(photoBytes: 2_300, videoBytes: 700))
    }

    func testUnclassifiableNamesCountAsOther() {
        let bytes = MediaTypeBytes.tabulate([
            MediaComponentBytes(filename: "notes.txt", bytes: 10),
            MediaComponentBytes(filename: "noextension", bytes: 20),
            MediaComponentBytes(filename: "thumb.encpreview", bytes: 30),
        ])

        XCTAssertEqual(bytes, MediaTypeBytes(otherBytes: 60))
        XCTAssertEqual(bytes.totalBytes, 60, "The total is the whole walk, not just what classified")
    }

    func testRecordNamesClassifyByTypeSuffixAndIgnoreChunkSuffix() {
        let bytes = MediaTypeBytes.tabulate([
            MediaComponentBytes(recordName: "a#0", bytes: 100),
            MediaComponentBytes(recordName: "b#1", bytes: 400),
            MediaComponentBytes(recordName: "b#1#c0", bytes: 250),
            MediaComponentBytes(recordName: "b#1#c1", bytes: 250),
            MediaComponentBytes(recordName: "stray", bytes: 7),
        ])

        XCTAssertEqual(bytes, MediaTypeBytes(photoBytes: 100, videoBytes: 900, otherBytes: 7))
    }

    /// A chunked Live Photo video track still groups with its photo by id.
    func testChunkedLivePhotoVideoTrackGroupsWithItsPhoto() {
        let bytes = MediaTypeBytes.tabulate([
            MediaComponentBytes(recordName: "live#0", bytes: 100),
            MediaComponentBytes(recordName: "live#1#c0", bytes: 900),
        ])

        XCTAssertEqual(bytes, MediaTypeBytes(photoBytes: 1_000))
    }

    func testSumAddsEveryField() {
        let sum = MediaTypeBytes(photoBytes: 1, videoBytes: 2, otherBytes: 3)
            + MediaTypeBytes(photoBytes: 10, videoBytes: 20, otherBytes: 30)

        XCTAssertEqual(sum, MediaTypeBytes(photoBytes: 11, videoBytes: 22, otherBytes: 33))
        XCTAssertEqual(sum.totalBytes, 66)
    }

    func testNegativeInputsAreClampedToZero() {
        XCTAssertEqual(MediaTypeBytes(photoBytes: -1, videoBytes: -2, otherBytes: -3), .zero)
        XCTAssertEqual(MediaTypeBytes.tabulate([MediaComponentBytes(filename: "a.encimage", bytes: -5)]), .zero)
    }
}
