//
//  VideoQualityOption.swift
//  EncameraCore
//

import Foundation
import AVFoundation

/// Represents a selectable video quality configuration combining resolution and frame rate.
public struct VideoQualityOption: Equatable, Hashable, Codable, Identifiable {
    public let width: Int32
    public let height: Int32
    public let frameRate: Int

    public var id: String {
        "\(width)x\(height)@\(frameRate)"
    }

    public init(width: Int32, height: Int32, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// Short resolution label like "4K", "1080p", "720p"
    public var resolutionLabel: String {
        switch Int(height) {
        case 2160: return "4K"
        case 1080: return "1080p"
        case 720: return "720p"
        case 480: return "480p"
        default:
            // For landscape formats where width > height
            switch Int(width) {
            case 3840: return "4K"
            case 1920: return "1080p"
            case 1280: return "720p"
            default: return "\(max(width, height))p"
            }
        }
    }

    /// Full display label like "4K 60fps" or "1080p 30fps"
    public var displayLabel: String {
        "\(resolutionLabel) \(frameRate)fps"
    }

    /// Pixel count for sorting
    public var pixelCount: Int {
        Int(width) * Int(height)
    }
}
