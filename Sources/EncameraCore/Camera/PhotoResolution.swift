//
//  PhotoResolution.swift
//  EncameraCore
//
//  Created by Claude on 30.03.26.
//

import Foundation
import AVFoundation

public struct PhotoResolution: Equatable, Hashable, Codable, Identifiable {
    public let width: Int32
    public let height: Int32

    public var id: String {
        "\(width)x\(height)"
    }

    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    public init(dimensions: CMVideoDimensions) {
        self.width = dimensions.width
        self.height = dimensions.height
    }

    public var megapixels: Double {
        Double(width) * Double(height) / 1_000_000.0
    }

    /// Display string like "12 MP" or "48 MP"
    public var displayLabel: String {
        let mp = Int(megapixels)
        return "\(mp) MP"
    }

    public var cmVideoDimensions: CMVideoDimensions {
        CMVideoDimensions(width: width, height: height)
    }
}
