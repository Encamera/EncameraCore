//
//  ReclaimableCacheEvicting.swift
//  EncameraCore
//
//  The seam the "Free up space" action calls through, so a view-model test can
//  prove eviction happens exactly once — and only after a confirmation — without
//  a real cache directory.
//

import Foundation

public protocol ReclaimableCacheEvicting: Sendable {
    /// Deletes every re-fetchable cached blob.
    ///
    /// Throws deliberately. A swallowed error here would report freed bytes while
    /// cached ciphertext survived on disk.
    func freeUpSpace() async throws

    /// What the cache thinks it holds, and what is actually on disk.
    ///
    /// The two are the same on a healthy cache; a gap is orphaned files. Only the
    /// on-device suite reads this — it is the one check a temp-directory fixture
    /// cannot make, because it needs a real Caches directory that a real eviction
    /// has run against.
    func indexedAndDiskBytes() async -> (indexed: Int64, disk: Int64)
}

extension CloudKitBlobCache: ReclaimableCacheEvicting {
    public func freeUpSpace() async throws {
        try await freeUpSpace(pendingUploads: .shared)
    }

    public func indexedAndDiskBytes() -> (indexed: Int64, disk: Int64) {
        (totalBytes(), diskBytes())
    }
}
