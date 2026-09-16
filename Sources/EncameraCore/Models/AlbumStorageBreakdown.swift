//
//  AlbumStorageBreakdown.swift
//  EncameraCore
//
//  One album's share of the storage figures. Held in memory by
//  `StorageUsageBreakdown.albums`; nothing renders it yet.
//

import Foundation

/// How many bytes one album accounts for, split by media type.
///
/// `albumID` is `Album.id`, which embeds the cleartext album name. It exists so a
/// later screen can map a row back to its album; it must never reach a log line,
/// a UI-test marker, or a screen that shows hidden albums.
public struct AlbumStorageBreakdown: Sendable, Equatable, Identifiable {

    public let albumID: String
    public let storageOption: StorageType
    /// Where the album's media lives: this device for `.local`, the cloud for
    /// `.cloudKit` and `.icloud`. `nil` when not knowable (no size sidecar on disk,
    /// iCloud Drive unreachable).
    public let mediaBytes: MediaTypeBytes?
    /// Re-fetchable on-device copies of a cloud album's media: the album's blob
    /// cache folder. `.zero` for `.local` and `.icloud`.
    public let cachedBytes: MediaTypeBytes
    /// The album's index and sidecar files.
    public let indexBytes: Int64

    public init(albumID: String,
                storageOption: StorageType,
                mediaBytes: MediaTypeBytes?,
                cachedBytes: MediaTypeBytes = .zero,
                indexBytes: Int64 = 0) {
        self.albumID = albumID
        self.storageOption = storageOption
        self.mediaBytes = mediaBytes
        self.cachedBytes = cachedBytes
        self.indexBytes = max(0, indexBytes)
    }

    public var id: String { albumID }

    /// Everything attributable to the album, wherever it lives. `nil` when the
    /// media figure is unknowable, because a partial total reads as a whole one.
    public var totalBytes: Int64? {
        mediaBytes.map { $0.totalBytes + cachedBytes.totalBytes + indexBytes }
    }
}
