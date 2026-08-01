//
//  CloudKitFlightCheckTests.swift
//  EncameraCoreTests
//
//  The flight check itself runs only against real CloudKit on a real device, but
//  the pieces its cancel/restart step judges by are decidable here — and if they
//  quietly stopped meaning what they say, that step would pass on a device where
//  the download bar is frozen.
//

import XCTest
@testable import EncameraCore

final class CloudKitFlightCheckTests: XCTestCase {

    /// The probe payload has to still be transferring a moment after it starts.
    /// A solid-colour JPEG compresses to a few KB and is gone before it can be
    /// cancelled, which would make the whole step vacuous.
    func testCancelProbePayloadIsLargeEnoughToCatchInFlight() throws {
        let payload = try CloudKitFlightCheck.makeIncompressibleJPEG()
        XCTAssertGreaterThan(payload.count, 15_000_000,
                             "The cancel/restart probe needs a payload whose cold download outlasts the cancel's "
                             + "release timeout, got \(payload.count) bytes")
    }

    /// The frozen-bar signature: `ensureLocalCiphertext` always reports
    /// `.downloading(0)` up front, so "0 and nothing else" is exactly what a
    /// caller sees when it joins a download it cannot hear.
    func testRecorderReportsNoProgressWhenOnlyTheOpeningZeroArrives() {
        let recorder = DownloadProgressRecorder()
        recorder.record(.downloading(progress: 0))

        XCTAssertFalse(recorder.sawDownloadProgress)
        XCTAssertNil(recorder.midFlightFraction)
    }

    func testRecorderReportsProgressOnceAFractionMoves() {
        let recorder = DownloadProgressRecorder()
        recorder.record(.downloading(progress: 0))
        recorder.record(.downloading(progress: 0.4))

        XCTAssertTrue(recorder.sawDownloadProgress)
        XCTAssertEqual(recorder.midFlightFraction, 0.4)
    }

    /// A download served entirely from cache reports only 1.0 — progress, but
    /// nothing that could ever have been cancelled mid-transfer.
    func testRecorderHasNoMidFlightFractionForAnInstantDownload() {
        let recorder = DownloadProgressRecorder()
        recorder.record(.downloading(progress: 1.0))

        XCTAssertTrue(recorder.sawDownloadProgress)
        XCTAssertNil(recorder.midFlightFraction)
    }

    /// Once the load moves on to decrypting there is nothing left to catch, so the
    /// probe must stop waiting instead of burning its whole timeout.
    func testRecorderReportsLeavingTheDownloadPhase() {
        let recorder = DownloadProgressRecorder()
        recorder.record(.downloading(progress: 0.5))
        XCTAssertFalse(recorder.isPastDownloading)

        recorder.record(.decrypting(progress: 0))
        XCTAssertTrue(recorder.isPastDownloading)
    }
}
