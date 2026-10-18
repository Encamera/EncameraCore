//
//  PhotoKitVideoLoader.swift
//  EncameraCore
//
//  Copies a photo-library video to a file the import pipeline can encrypt.
//
//  PhotoKit returns an `AVURLAsset` for an unedited video but an `AVComposition`
//  for a slow-motion one (the high-frame-rate original plus Photos' time ramp) and
//  for some edits. A slow-motion ramp is kept as metadata over the untouched
//  original; any other composition is rendered to a file.
//

import AVFoundation
import Photos

public enum PhotoKitVideoLoader {

    /// What to do with the asset `requestAVAsset` returned for the current version.
    public enum Plan: Equatable {
        /// An unedited file: copy it as is.
        case copy(URL)
        /// Slow motion: copy the original and keep this ramp.
        case original(SlowMotionRamp)
        /// Any other composition: render the current version.
        case render
    }

    public static func plan(for asset: AVAsset) -> Plan {
        if let urlAsset = asset as? AVURLAsset {
            return .copy(urlAsset.url)
        }
        if let composition = asset as? AVComposition, let ramp = SlowMotionRamp(composition: composition) {
            return .original(ramp)
        }
        return .render
    }

    /// Writes the video to `destination` and returns its slow-motion ramp, if any.
    /// A caller that cannot store the ramp passes `keepingSlowMotion: false` and
    /// gets slow motion rendered into the file instead. `progress` reports 0...1
    /// while iCloud downloads the video, on any queue.
    public static func load(_ asset: PHAsset,
                            to destination: URL,
                            keepingSlowMotion: Bool = true,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SlowMotionRamp? {
        let current = try await requestAVAsset(asset, version: .current, progress: progress)
        var decision = plan(for: current)
        if case .original = decision, !keepingSlowMotion {
            decision = .render
        }
        switch decision {
        case .copy(let url):
            try FileManager.default.copyItem(at: url, to: destination)
            return nil
        case .original(let ramp):
            let original = try await requestAVAsset(asset, version: .original, progress: progress)
            guard let urlAsset = original as? AVURLAsset else {
                try await render(asset, to: destination)
                return nil
            }
            try FileManager.default.copyItem(at: urlAsset.url, to: destination)
            return ramp
        case .render:
            try await render(asset, to: destination)
            return nil
        }
    }

    private static func requestAVAsset(_ asset: PHAsset,
                                       version: PHVideoRequestOptionsVersion,
                                       progress: @escaping @Sendable (Double) -> Void) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = version
            options.progressHandler = { fraction, _, _, _ in progress(fraction) }
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: BackgroundImportError.fromPhotoKitInfo(info))
                }
            }
        }
    }

    /// HEVC keeps 10-bit HDR; the plain preset covers devices without an HEVC encoder.
    private static func render(_ asset: PHAsset, to destination: URL) async throws {
        for preset in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            guard let export = try? await requestExportSession(asset, preset: preset) else { continue }
            try? FileManager.default.removeItem(at: destination)
            do {
                try await export.export(to: destination, as: .mov)
                return
            } catch {
                continue
            }
        }
        throw BackgroundImportError.videoExportFailed
    }

    private static func requestExportSession(_ asset: PHAsset, preset: String) async throws -> AVAssetExportSession {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestExportSession(forVideo: asset, options: options, exportPreset: preset) { session, info in
                if let session {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: BackgroundImportError.fromPhotoKitInfo(info))
                }
            }
        }
    }
}
