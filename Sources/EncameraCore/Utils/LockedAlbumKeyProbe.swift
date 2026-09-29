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
    public static func requiredKey(albumDirectory: URL) -> RequiredKeyIdentity? {
        let mediaExtensions: Set<String> = [MediaType.photo.encryptedFileExtension,
                                            MediaType.video.encryptedFileExtension]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: albumDirectory,
                                                                          includingPropertiesForKeys: nil) else {
            return nil
        }
        let stamps = Set(contents
            .filter { mediaExtensions.contains($0.pathExtension) }
            .prefix(maxFilesProbed)
            .compactMap(KeyStampSlot.readStamp(url:)))
        guard stamps.count == 1, let stamp = stamps.first else {
            return nil
        }
        return .stampPrefix(stamp)
    }
}
