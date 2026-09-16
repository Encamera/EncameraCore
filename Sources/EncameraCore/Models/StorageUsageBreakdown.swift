//
//  StorageUsageBreakdown.swift
//  EncameraCore
//
//  The value type the Storage Insights screen renders. See
//  `Documentation/storage-accounting-model.md` for the decisions behind it.
//

import Foundation

/// How many bytes Encamera occupies, split by where the bytes are, what they are,
/// and whether the user can get them back.
///
/// The device buckets are disjoint — no byte is counted twice — so they sum to
/// `totalDeviceBytes`.
///
/// The cloud figures are a *different location*, not extra buckets, and
/// `cloudKitMedia` **overlaps** `cachedCloud` by design: a downloaded blob occupies
/// both CloudKit and this device's disk, and is counted once in each. The two are
/// therefore never summed.
public struct StorageUsageBreakdown: Sendable, Equatable {

    // MARK: Device

    /// Encrypted media in `.local` albums. Irreplaceable — this is the only copy.
    public let localMedia: MediaTypeBytes
    /// The CloudKit blob cache. Re-fetchable ciphertext.
    public let cachedCloud: MediaTypeBytes
    /// Preview thumbnails. Regenerable from the media they preview.
    public let thumbnailBytes: Int64
    /// Per-album media indexes and sidecars. Derived, and small.
    public let indexBytes: Int64

    // MARK: Cloud

    /// Media in the user's private CloudKit database, cached here or not. `nil`
    /// means "not knowable right now" — an album with no size sidecar yet — which is
    /// a different statement from zero.
    public let cloudKitMedia: MediaTypeBytes?
    /// Media in legacy iCloud Drive albums, at the logical size the cloud holds.
    /// `nil` when iCloud Drive is unreachable; `.zero` when there are no such albums.
    public let iCloudDriveMedia: MediaTypeBytes?

    // MARK: Per album

    /// One entry per album the walk saw, hidden albums included. In memory only:
    /// the ids carry cleartext names.
    public let albums: [AlbumStorageBreakdown]
    /// How many legacy iCloud Drive albums exist. Their on-device copies are
    /// excluded from every device bucket (see the accounting model); a non-zero
    /// count is what makes the screen say so instead of silently under-reporting.
    public let legacyICloudDriveAlbumCount: Int

    public init(
        localMedia: MediaTypeBytes = .zero,
        cachedCloud: MediaTypeBytes = .zero,
        thumbnailBytes: Int64 = 0,
        indexBytes: Int64 = 0,
        cloudKitMedia: MediaTypeBytes? = nil,
        iCloudDriveMedia: MediaTypeBytes? = .zero,
        albums: [AlbumStorageBreakdown] = [],
        legacyICloudDriveAlbumCount: Int = 0
    ) {
        self.localMedia = localMedia
        self.cachedCloud = cachedCloud
        self.thumbnailBytes = max(0, thumbnailBytes)
        self.indexBytes = max(0, indexBytes)
        self.cloudKitMedia = cloudKitMedia
        self.iCloudDriveMedia = iCloudDriveMedia
        self.albums = albums
        self.legacyICloudDriveAlbumCount = max(0, legacyICloudDriveAlbumCount)
    }

    /// Scalar form for callers that have totals and no split: local media counts as
    /// photos, the cache as unclassified, and `cloudBytes` as CloudKit with no
    /// iCloud Drive albums. Negative inputs are clamped to zero.
    public init(
        localMediaBytes: Int64 = 0,
        cachedCloudBytes: Int64 = 0,
        thumbnailBytes: Int64 = 0,
        indexBytes: Int64 = 0,
        cloudBytes: Int64? = nil,
        legacyICloudDriveAlbumCount: Int = 0
    ) {
        self.init(
            localMedia: MediaTypeBytes(photoBytes: localMediaBytes),
            cachedCloud: MediaTypeBytes(otherBytes: cachedCloudBytes),
            thumbnailBytes: thumbnailBytes,
            indexBytes: indexBytes,
            cloudKitMedia: cloudBytes.map { MediaTypeBytes(otherBytes: $0) },
            iCloudDriveMedia: .zero,
            legacyICloudDriveAlbumCount: legacyICloudDriveAlbumCount
        )
    }

    // MARK: - Device

    public var localMediaBytes: Int64 { localMedia.totalBytes }

    public var cachedCloudBytes: Int64 { cachedCloud.totalBytes }

    /// Everything Encamera occupies on this device's disk. Excludes the cloud
    /// figures, which are not on this device.
    public var totalDeviceBytes: Int64 {
        localMediaBytes + cachedCloudBytes + thumbnailBytes + indexBytes
    }

    /// The bytes the user can free without losing anything: re-fetchable cache plus
    /// regenerable thumbnails and indexes.
    ///
    /// Never includes local media. "Free up space" is wired to this number, so the
    /// moment local media leaks in, the button starts deleting photos.
    /// Invariant: `0 <= reclaimableBytes <= totalDeviceBytes`, which holds because
    /// these terms are a subset of that sum.
    public var reclaimableBytes: Int64 {
        cachedCloudBytes + thumbnailBytes + indexBytes
    }

    /// True when there is nothing on disk to show — the screen renders its empty
    /// state rather than a ring of zero-width slices.
    public var isEmpty: Bool {
        totalDeviceBytes == 0
    }

    // MARK: - Cloud

    /// Media in iCloud by either method. `nil` when either method is unknowable: a
    /// partial sum rendered as a total is a lie, not an approximation.
    public var cloudMedia: MediaTypeBytes? {
        guard let cloudKitMedia, let iCloudDriveMedia else { return nil }
        return cloudKitMedia + iCloudDriveMedia
    }

    public var cloudBytes: Int64? {
        cloudMedia?.totalBytes
    }

    public var isCloudEmpty: Bool {
        cloudBytes == 0
    }

    /// The fraction of the user's iCloud bytes held in CloudKit rather than iCloud
    /// Drive, 0...1. `nil` when the cloud figure is unknowable or zero.
    public var cloudKitShareOfCloud: Double? {
        guard let cloudKitMedia, let total = cloudBytes, total > 0 else { return nil }
        return Double(cloudKitMedia.totalBytes) / Double(total)
    }
}
