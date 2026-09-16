//
//  ICloudDriveSizing.swift
//  EncameraCore
//
//  How the storage calculator sizes a legacy iCloud Drive album. A seam rather than
//  a direct call because the real query needs a ubiquity container, which no unit
//  test or simulator has.
//

import Foundation

public protocol ICloudDriveSizing: Sendable {
    /// Whether iCloud Drive can be asked at all. Answered before any album URL is
    /// built: `iCloudStorageModel.rootURL` traps on a device with no container.
    var isReachable: Bool { get }

    /// Logical byte size per file in the album directory, keyed by the materialized
    /// filename (`<id>.<ext>`), whether or not the file is downloaded. `nil` when
    /// iCloud Drive is unreachable.
    func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]?
}

/// The production sizer, over `ICloudDriveMaterializer`'s metadata query.
public struct ICloudDriveSizer: ICloudDriveSizing {

    /// Much shorter than the materializer's default: the storage screen sizes albums
    /// one after another, and a query that stays silent would otherwise hold the
    /// whole screen for every album.
    public static let gatherTimeout: TimeInterval = 5

    public init() {}

    public var isReachable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    public func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64]? {
        guard isReachable else { return nil }
        return await Self.gather(directory)
    }

    @MainActor
    private static func gather(_ directory: URL) async -> [String: Int64] {
        await ICloudDriveMaterializer(gatherTimeout: gatherTimeout).logicalSizes(inAlbumDirectory: directory)
    }
}
