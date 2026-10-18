//
//  SlowMotionRampTests.swift
//  EncameraCoreTests
//
//  Covers storing a slow-motion ramp, reading one off a Photos-style composition,
//  rebuilding slow motion from it, and the import loader's choice between copying,
//  keeping the original with its ramp, and rendering.
//

import AVFoundation
import XCTest
@testable import EncameraCore

final class SlowMotionRampTests: XCTestCase {

    /// `native.mov` is 1 s at 25 fps; 0.2–0.6 s slowed 4x plays for 2.2 s.
    private let ramp = SlowMotionRamp(segments: [
        .init(sourceStart: CMTime(value: 120, timescale: 600),
              sourceDuration: CMTime(value: 240, timescale: 600),
              targetDuration: CMTime(value: 960, timescale: 600))
    ])

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let testBundle = Bundle(for: Self.self)
        let candidates = [
            testBundle.url(forResource: name, withExtension: ext),
            testBundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        ]
        return try XCTUnwrap(candidates.compactMap { $0 }.first, "Missing fixture \(name).\(ext)")
    }

    private func assertClose(_ lhs: CMTime, _ rhs: CMTime, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.seconds, rhs.seconds, accuracy: 0.002, message, file: file, line: line)
    }

    // MARK: - Coding

    func testRampRoundTripsThroughMetadataJSON() throws {
        var metadata = EncryptedFileMetadata()
        metadata.video = .init(duration: 2.2, frameRate: 240, slowMotion: ramp)
        let data = try EncryptedMetadataHandler.encodeMetadata(metadata)
        let decoded = try EncryptedMetadataHandler.decodeMetadata(data)
        XCTAssertEqual(decoded.video?.slowMotion, ramp)
    }

    func testVideoInfoWrittenBeforeSlowMotionStillDecodes() throws {
        let json = #"{"duration":3.3,"frameRate":240,"hasAudio":true}"#
        let info = try JSONDecoder().decode(EncryptedFileMetadata.VideoInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.duration, 3.3)
        XCTAssertNil(info.slowMotion)
    }

    func testPlaybackDurationAddsTheSlowedTime() {
        assertClose(ramp.playbackDuration(sourceDuration: CMTime(seconds: 1, preferredTimescale: 600)),
                    CMTime(seconds: 2.2, preferredTimescale: 600))
    }

    // MARK: - Composer

    func testComposerSlowsTheRampedSpanAndKeepsEveryFrame() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let composition = try await SlowMotionComposer.asset(for: source, ramp: ramp)

        assertClose(composition.duration, CMTime(seconds: 2.2, preferredTimescale: 600), "composition duration")

        let sourceTransform = try await source.loadTracks(withMediaType: .video).first?.load(.preferredTransform)
        XCTAssertEqual(composition.tracks(withMediaType: .video).first?.preferredTransform, sourceTransform)

        let composedFrames = try await frameCount(composition)
        let sourceFrames = try await frameCount(source)
        XCTAssertEqual(composedFrames, sourceFrames, "slowing a span must not drop or duplicate frames")
    }

    private func frameCount(_ asset: AVAsset) async throws -> Int {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        XCTAssertEqual(reader.status, .completed)
        return count
    }

    // MARK: - Reading a ramp off a composition

    func testRampReadBackFromAComposedAssetMatches() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let composition = try await SlowMotionComposer.asset(for: source, ramp: ramp)

        let extracted = try XCTUnwrap(SlowMotionRamp(composition: composition))
        XCTAssertEqual(extracted.segments.count, 1)
        let segment = try XCTUnwrap(extracted.segments.first)
        assertClose(segment.sourceStart.cmTime, CMTime(value: 120, timescale: 600), "sourceStart")
        assertClose(segment.sourceDuration.cmTime, CMTime(value: 240, timescale: 600), "sourceDuration")
        assertClose(segment.targetDuration.cmTime, CMTime(value: 960, timescale: 600), "targetDuration")
    }

    func testUnscaledCompositionHasNoRamp() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let composition = AVMutableComposition()
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: try await source.load(.duration)),
                                              of: source, at: .zero)
        XCTAssertNil(SlowMotionRamp(composition: composition))
    }

    func testCompositionOfTwoFilesHasNoRamp() async throws {
        let first = AVURLAsset(url: try fixture("native", "mov"))
        let second = AVURLAsset(url: try fixture("native", "mp4"))
        let composition = AVMutableComposition()
        let firstDuration = try await first.load(.duration)
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: firstDuration), of: first, at: .zero)
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: try await second.load(.duration)),
                                              of: second, at: firstDuration)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 120, timescale: 600)),
                                   toDuration: CMTime(value: 480, timescale: 600))
        XCTAssertNil(SlowMotionRamp(composition: composition), "two sources is an edit, not a ramp")
    }

    func testTrimmedCompositionHasNoRamp() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let composition = AVMutableComposition()
        let duration = try await source.load(.duration)
        let start = CMTime(value: 120, timescale: 600)
        try await composition.insertTimeRange(CMTimeRange(start: start, end: duration), of: source, at: .zero)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: start),
                                   toDuration: CMTimeMultiply(start, multiplier: 4))
        XCTAssertNil(SlowMotionRamp(composition: composition), "a trim is an edit, not a ramp")
    }

    // MARK: - Import plan

    func testPlainFileIsCopied() throws {
        let url = try fixture("native", "mov")
        XCTAssertEqual(PhotoKitVideoLoader.plan(for: AVURLAsset(url: url)), .copy(url))
    }

    func testSlowMotionCompositionKeepsTheOriginalAndItsRamp() async throws {
        let composition = try await SlowMotionComposer.asset(for: AVURLAsset(url: try fixture("native", "mov")), ramp: ramp)
        guard case .original(let extracted) = PhotoKitVideoLoader.plan(for: composition) else {
            return XCTFail("a slow-motion composition should keep the original")
        }
        XCTAssertEqual(extracted.segments.count, 1)
    }

    func testOtherEditsAreRendered() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let composition = AVMutableComposition()
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: try await source.load(.duration)),
                                              of: source, at: .zero)
        XCTAssertEqual(PhotoKitVideoLoader.plan(for: composition), .render)
    }

    func testFailedVideoExportIsReportedAsATranscodeFailure() {
        XCTAssertEqual(ImportSkipReason(error: BackgroundImportError.videoExportFailed), .transcodeFailed)
    }
}

extension SlowMotionRampTests {

    func testPlayerItemPlaysTheRampSlowed() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let item = await SlowMotionComposer.playerItem(for: source, ramp: ramp)
        XCTAssertTrue(item.asset is AVComposition)
        XCTAssertEqual(item.audioTimePitchAlgorithm, .spectral)
        let duration = try await item.asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2.2, accuracy: 0.002)
    }

    func testPlayerItemWithoutARampPlaysTheFileAsIs() async throws {
        let source = AVURLAsset(url: try fixture("native", "mov"))
        let item = await SlowMotionComposer.playerItem(for: source, ramp: nil)
        XCTAssertTrue(item.asset === source)
    }
}

extension SlowMotionRampTests {

    func testSharingASlowMotionVideoHandsOutTheSlowedVersionUnderItsName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decrypted = directory.appendingPathComponent("IMG_0001.mov")
        try FileManager.default.copyItem(at: try fixture("native", "mov"), to: decrypted)

        let shared = await ShareMediaUtil.shareableURL(for: decrypted, slowMotion: ramp)

        XCTAssertNotEqual(shared, decrypted)
        XCTAssertEqual(shared.lastPathComponent, "IMG_0001.mov")
        let duration = try await AVURLAsset(url: shared).load(.duration)
        XCTAssertEqual(duration.seconds, 2.2, accuracy: 0.1, "the shared file should play slowed on its own")
    }

    func testSharingAnOrdinaryVideoHandsOutTheFileAsIs() async throws {
        let decrypted = try fixture("native", "mov")
        let shared = await ShareMediaUtil.shareableURL(for: decrypted, slowMotion: nil)
        XCTAssertEqual(shared, decrypted)
    }
}
