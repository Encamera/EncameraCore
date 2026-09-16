//
//  MediaTypeBytes.swift
//  EncameraCore
//
//  Bytes split by media type, and the one rule that decides which type a file's
//  bytes belong to. Every storage walk (local albums, the blob cache, the CloudKit
//  size sidecar, iCloud Drive) tabulates through here so a Live Photo is counted
//  the same way wherever its bytes live.
//

import Foundation

/// One file or record and the bytes it occupies, before classification.
public struct MediaComponentBytes: Sendable, Equatable {
    /// The media id: the shared stem of a Live Photo's two files.
    public let id: String
    /// `nil` when the name carries no media type at all (a stray file, a
    /// bookkeeping file), as opposed to `.unknown`.
    public let type: MediaType?
    public let bytes: Int64

    public init(id: String, type: MediaType?, bytes: Int64) {
        self.id = id
        self.type = type
        self.bytes = bytes
    }

    /// Classifies an encrypted media filename, `<id>.<encryptedFileExtension>`.
    /// Takes the second dot-component so a name with a trailing suffix still
    /// classifies, the same idiom `MediaType.typeFromURL` uses.
    public init(filename: String, bytes: Int64) {
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false)
        let id = parts.first.map(String.init) ?? filename
        let type = parts.count > 1
            ? MediaType.allCases.first { $0.encryptedFileExtension == parts[1] }
            : nil
        self.init(id: id, type: type, bytes: bytes)
    }

    /// Classifies a CloudKit record name (`<id>#<type>`) or a blob-cache filename,
    /// which is a record name optionally followed by a `#c<n>` chunk suffix.
    public init(recordName: String, bytes: Int64) {
        let parsed = MediaRecordName.parseCachedFileName(recordName)
        self.init(id: parsed.id, type: parsed.type, bytes: bytes)
    }
}

/// Bytes split into photos, videos and everything else.
public struct MediaTypeBytes: Sendable, Equatable {

    /// Still photos, plus every component of a Live Photo.
    public let photoBytes: Int64
    /// Standalone videos.
    public let videoBytes: Int64
    /// Files whose name names no media type. Kept so a total is the whole walk and
    /// not just the part that classified.
    public let otherBytes: Int64

    public static let zero = MediaTypeBytes()

    /// Negative inputs are clamped to zero, as `StorageUsageBreakdown` does.
    public init(photoBytes: Int64 = 0, videoBytes: Int64 = 0, otherBytes: Int64 = 0) {
        self.photoBytes = max(0, photoBytes)
        self.videoBytes = max(0, videoBytes)
        self.otherBytes = max(0, otherBytes)
    }

    public var totalBytes: Int64 {
        photoBytes + videoBytes + otherBytes
    }

    public static func + (lhs: MediaTypeBytes, rhs: MediaTypeBytes) -> MediaTypeBytes {
        MediaTypeBytes(photoBytes: lhs.photoBytes + rhs.photoBytes,
                       videoBytes: lhs.videoBytes + rhs.videoBytes,
                       otherBytes: lhs.otherBytes + rhs.otherBytes)
    }

    /// Groups components by id and assigns each group whole: a group with any photo
    /// component is all photo, so a Live Photo's video track counts as part of the
    /// photo; a group with a video component and no photo is a video; anything else
    /// is `other`.
    public static func tabulate(_ components: [MediaComponentBytes]) -> MediaTypeBytes {
        var groups: [String: [MediaComponentBytes]] = [:]
        for component in components {
            groups[component.id, default: []].append(component)
        }
        var photo: Int64 = 0
        var video: Int64 = 0
        var other: Int64 = 0
        for group in groups.values {
            let bytes = group.reduce(0) { $0 + max(0, $1.bytes) }
            if group.contains(where: { $0.type == .photo }) {
                photo += bytes
            } else if group.contains(where: { $0.type == .video }) {
                video += bytes
            } else {
                other += bytes
            }
        }
        return MediaTypeBytes(photoBytes: photo, videoBytes: video, otherBytes: other)
    }
}
