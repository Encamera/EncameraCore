//
//  SlowMotionComposer.swift
//  EncameraCore
//
//  Rebuilds slow motion from a stored original and its `SlowMotionRamp`. Works
//  on any asset, including one streamed through `EncryptedStreamResourceLoader`.
//

import AVFoundation

public enum SlowMotionComposerError: Error {
    case exportFailed
}

public enum SlowMotionComposer {

    public static func asset(for source: AVAsset, ramp: SlowMotionRamp) async throws -> AVComposition {
        let duration = try await source.load(.duration)
        let transform = try await source.loadTracks(withMediaType: .video).first?.load(.preferredTransform)

        let composition = AVMutableComposition()
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        if let transform {
            composition.tracks(withMediaType: .video).first?.preferredTransform = transform
        }
        // Last span first: scaling a span moves everything after it, never before.
        for segment in ramp.segments.sorted(by: { $0.sourceStart.cmTime > $1.sourceStart.cmTime }) {
            composition.scaleTimeRange(segment.sourceRange, toDuration: segment.targetDuration.cmTime)
        }
        return composition
    }

    /// An item that plays `source` slowed by `ramp`, or at normal speed when there is
    /// no ramp or it cannot be applied.
    public static func playerItem(for source: AVAsset, ramp: SlowMotionRamp?) async -> AVPlayerItem {
        guard let ramp, let composition = try? await asset(for: source, ramp: ramp) else {
            return AVPlayerItem(asset: source)
        }
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    /// Renders `source` slowed by `ramp` into a new movie, for handing a slow-motion
    /// video to something outside the app. HEVC keeps 10-bit HDR; the plain preset
    /// covers devices without an HEVC encoder.
    public static func render(_ source: URL, ramp: SlowMotionRamp, to destination: URL) async throws {
        let composition = try await asset(for: AVURLAsset(url: source), ramp: ramp)
        for preset in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            export.audioTimePitchAlgorithm = .spectral
            try? FileManager.default.removeItem(at: destination)
            do {
                try await export.export(to: destination, as: .mov)
                return
            } catch {
                continue
            }
        }
        throw SlowMotionComposerError.exportFailed
    }
}
