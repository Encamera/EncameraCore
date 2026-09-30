//
//  DeviceFreeSpace.swift
//  EncameraCore
//

import Foundation

/// Free space on the device volume, for deciding whether an import will fit.
///
/// The value is a required-reason API result (E174.1): it may drive on-device
/// decisions only and must never be logged, tracked or sent off the device.
public protocol DeviceFreeSpaceProviding: Sendable {
    /// Bytes available for a user-initiated write, or `nil` when unknown.
    func availableBytesForImport() -> Int64?
}

/// Reads `volumeAvailableCapacityForImportantUsage`, which counts purgeable
/// space iOS will reclaim for a user-initiated save.
public struct LiveDeviceFreeSpace: DeviceFreeSpaceProviding {
    public init() {}

    public func availableBytesForImport() -> Int64? {
        (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
    }
}

/// A test double whose value is fixed, or produced by a closure so free space
/// can shrink between calls.
public struct FixedDeviceFreeSpace: DeviceFreeSpaceProviding {
    private let provider: @Sendable () -> Int64?

    public init(_ bytes: Int64?) {
        provider = { bytes }
    }

    public init(_ provider: @escaping @Sendable () -> Int64?) {
        self.provider = provider
    }

    public func availableBytesForImport() -> Int64? {
        provider()
    }
}
