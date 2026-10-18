//
//  SlowMotionRamp.swift
//  EncameraCore
//
//  The time ramp Photos applies to a slow-motion video. The stored file is the
//  untouched high-frame-rate original; playback rebuilds the slow motion from
//  this ramp with `SlowMotionComposer`.
//

import AVFoundation
import Foundation

public struct SlowMotionRamp: Codable, Equatable, Sendable {

    /// A `CMTime` that encodes exactly, so a stored ramp rebuilds the same timeline.
    public struct Time: Codable, Equatable, Sendable {
        public var value: Int64
        public var timescale: Int32

        public init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
        }

        public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    }

    /// A span of the original that plays over `targetDuration` instead of `sourceDuration`.
    public struct Segment: Codable, Equatable, Sendable {
        public var sourceStart: Time
        public var sourceDuration: Time
        public var targetDuration: Time

        public init(sourceStart: CMTime, sourceDuration: CMTime, targetDuration: CMTime) {
            self.sourceStart = Time(sourceStart)
            self.sourceDuration = Time(sourceDuration)
            self.targetDuration = Time(targetDuration)
        }

        public var sourceRange: CMTimeRange {
            CMTimeRange(start: sourceStart.cmTime, duration: sourceDuration.cmTime)
        }
    }

    /// Only the scaled spans, in source order. Everything else plays at normal speed.
    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// How long the original plays for once the ramp is applied.
    public func playbackDuration(sourceDuration: CMTime) -> CMTime {
        segments.reduce(sourceDuration) { total, segment in
            total - segment.sourceDuration.cmTime + segment.targetDuration.cmTime
        }
    }

    /// Reads the ramp off a composition Photos returned for a slow-motion asset.
    ///
    /// Returns nil unless the composition is the whole of one source file, in order,
    /// with at least one span time-scaled — anything else is an edit this ramp
    /// cannot describe, and has to be rendered instead.
    public init?(composition: AVComposition) {
        guard let video = composition.tracks(withMediaType: .video).first,
              Self.drawsFromSingleSource(composition),
              let scaled = Self.scaledSegments(of: video),
              !scaled.isEmpty else { return nil }
        self.init(segments: scaled)
    }

    /// Whether every non-empty segment on every track reads from the same file.
    private static func drawsFromSingleSource(_ composition: AVComposition) -> Bool {
        var sourceURL: URL?
        for track in composition.tracks {
            for segment in track.segments where !segment.isEmpty {
                guard let url = segment.sourceURL else { return false }
                if let sourceURL, sourceURL != url { return false }
                sourceURL = url
            }
        }
        return true
    }

    /// The time-scaled spans of `video`, or nil if its segments leave a gap or
    /// play the source out of order.
    private static func scaledSegments(of video: AVCompositionTrack) -> [Segment]? {
        var expectedSourceStart = CMTime.zero
        var expectedTargetStart = CMTime.zero
        var scaled: [Segment] = []
        for segment in video.segments {
            guard !segment.isEmpty else { return nil }
            let source = segment.timeMapping.source
            let target = segment.timeMapping.target
            guard isClose(source.start, expectedSourceStart),
                  isClose(target.start, expectedTargetStart) else { return nil }
            if !isClose(source.duration, target.duration) {
                scaled.append(Segment(sourceStart: source.start,
                                      sourceDuration: source.duration,
                                      targetDuration: target.duration))
            }
            expectedSourceStart = source.end
            expectedTargetStart = target.end
        }
        return scaled
    }

    /// Within a millisecond: compositions round segment boundaries to their timescale.
    private static func isClose(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        abs(CMTimeGetSeconds(lhs) - CMTimeGetSeconds(rhs)) < 0.001
    }
}
