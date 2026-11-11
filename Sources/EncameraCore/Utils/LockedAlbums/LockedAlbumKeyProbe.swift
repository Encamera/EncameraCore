//
//  LockedAlbumKeyProbe.swift
//  EncameraCore
//
//  Names the key a locked local or iCloud Drive album needs.
//

import Foundation

/// Reads which key a locked directory album needs from the stamps on its media.
///
/// A directory album's encrypted name proves a key but cannot name one. Its
/// media can: a local file is stamped with its key's prefix when opened.
/// iCloud Drive files and never-opened local files carry no stamp, so nil is
/// common and means unknown.
public enum LockedAlbumKeyProbe {

    /// Upper bound on files read per album, so a grid scan over locked albums
    /// stays a handful of small reads each.
    static let maxFilesProbed = 8

    /// The stamp the album's media agrees on, or nil when no probed file is
    /// stamped or two stamped files disagree. A disagreement means the stamps
    /// cannot say which key encrypted the album's name, and naming the wrong
    /// one would reject the phrase that actually opens it.
    ///
    /// Reads files, so it runs only inside the background content probe
    /// (`AlbumManager.startContentProbe`), never from a listing.
    public static func requiredKey(albumDirectory: URL) -> RequiredKeyIdentity? {
        guard let files = LockedAlbumProbeFiles.downloadedMediaFiles(in: albumDirectory) else {
            return nil
        }
        let stamps = Set(files
            .prefix(maxFilesProbed)
            .compactMap { url -> UInt32? in
                LockedAlbumProbeFiles.onMediaFileOpened?(url)
                return KeyStampSlot.readStamp(url: url)
            })
        guard stamps.count == 1, let stamp = stamps.first else {
            return nil
        }
        return .stampPrefix(stamp)
    }
}

/// The media files the locked-album probes may read.
enum LockedAlbumProbeFiles {

    /// Whether a file's bytes are not on disk. A read of such a file waits on an
    /// iCloud Drive download, which may never finish offline, so the probes skip
    /// it rather than start or wait for one. Reads resource values only.
    @TaskLocal static var needsDownload: @Sendable (URL) -> Bool = { iCloudFileStatusUtil.needsDownload(url: $0) }

    /// Called before a probe reads a media file, for tests. Task-local, so a
    /// probe running on its own detached task does not report to it.
    @TaskLocal static var onMediaFileOpened: (@Sendable (URL) -> Void)?

    /// The encrypted photos and videos in `directory` whose bytes are on disk,
    /// or nil when the directory cannot be listed.
    static func downloadedMediaFiles(in directory: URL) -> [URL]? {
        let mediaExtensions: Set<String> = [MediaType.photo.encryptedFileExtension,
                                            MediaType.video.encryptedFileExtension]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: nil) else {
            return nil
        }
        let skipUndownloaded = needsDownload
        return contents
            .filter { mediaExtensions.contains($0.pathExtension) }
            .filter { !skipUndownloaded($0) }
    }
}
