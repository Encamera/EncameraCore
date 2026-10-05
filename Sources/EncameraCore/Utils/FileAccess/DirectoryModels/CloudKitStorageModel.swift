//
//  CloudKitStorageModel.swift
//  EncameraCore
//
//  Compatibility shim for URL-expecting code (e.g. `Album.storageURL`) on CloudKit
//  albums. CloudKit albums have no on-disk album directory of record; this model
//  points `baseURL` at the album's local CloudKit blob cache directory so those
//  callers degrade gracefully. The authoritative store is CloudKit — this is only
//  the local materialization point. `.local` albums never touch this. (Chunk 04.)
//

import Foundation
import CryptoKit

struct CloudKitStorageModel: DataStorageModel {

    /// Root of the per-album CloudKit blob cache, shared with `CloudKitBlobCache`.
    static var rootURL: URL {
        CloudKitBlobCache.defaultBaseDir
    }

    /// The album markers' root in Application Support, not `rootURL/albums`: the
    /// blob cache root is in Caches, which the OS may purge.
    static var albumsURL: URL {
        CloudKitAlbumMarker.rootDirectoryURL
    }

    var storageType: StorageType { .cloudKit }

    let album: Album

    init(album: Album) {
        self.album = album
    }

    /// Per-album cache directory. Keyed by the album's `albumID`, the same id the
    /// blob cache and sync coordinator use (so they share one tree), made
    /// filesystem-safe via `CloudKitBlobCache.albumFolderName`. No cleartext album
    /// name on disk, and a rename leaves the directory where it is.
    ///
    /// Pure getter (matches `LocalDirectoryModel.baseURL`): it computes the URL and
    /// performs NO filesystem I/O. Creating the directory here would defeat
    /// `AlbumManager.create`'s "does this album already exist?" check — which reads
    /// `album.storageURL` to get the path and would then always find it present. The
    /// directory is created lazily by the actual writers (`AlbumManager.create`,
    /// `CloudKitFileAccess.saveSingle`, `CloudKitBlobCache.store`). It lives under
    /// `Library/Caches` (already excluded from backup), and the blob cache also
    /// excludes each stored file, so no explicit exclusion is needed here.
    var baseURL: URL {
        guard let albumID = album.albumID else {
            assertionFailure("a CloudKit album has no albumID")
            return Self.rootURL.appendingPathComponent("unidentified-album", isDirectory: true)
        }
        return Self.rootURL.appendingPathComponent(CloudKitBlobCache.albumFolderName(albumID), isDirectory: true)
    }
}
