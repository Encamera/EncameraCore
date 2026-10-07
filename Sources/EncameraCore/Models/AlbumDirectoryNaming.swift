//
//  AlbumDirectoryNaming.swift
//  EncameraCore
//

import Foundation

/// Which directory names at a storage root are albums.
///
/// Two naming schemes are in the wild and both are load-bearing:
///
/// - `Album_<base64>` — the album name encrypted with the album key
///   (`Album.encryptedPathComponent`). Everything created since name encryption.
/// - A plaintext album name — everything created before it. These are not
///   convertible: the directory name IS the album's identity, and `Album.id`
///   plus every name-derived `UserDefaults` key are built from it.
///
/// So an album directory cannot be recognized by a prefix. It is recognized by
/// elimination: any directory at the root that is not one of the known non-album
/// siblings. That is the rule the app shipped with before the `albums/`
/// subdirectory existed, and re-adopting it is what makes pre-encryption albums
/// visible again.
public enum AlbumDirectoryNaming {

    /// The directory holding albums, relative to a storage root.
    public static let albumsDirectory = "albums"

    /// Names at a storage root that are definitively not albums.
    ///
    /// Compared case-insensitively — `RevenueCat` has shipped under both casings,
    /// and the pre-`albums/` exclusion list carried each spelling separately.
    private static let reservedNames: Set<String> = [
        albumsDirectory,
        AppConstants.previewDirectory,
        "thumbs",
        "inbox",          // created by iOS document interaction, never by us
        ".trash",         // iCloud Drive
        // Volume bookkeeping a filesystem or the Files app can leave at a root.
        ".trashes",
        ".fseventsd",
        ".spotlight-v100",
        ".documentrevisions-v100",
        ".temporaryitems"
    ]

    /// Substrings that mark a directory as SDK infrastructure, not an album.
    private static let reservedSubstrings: [String] = [
        "revenuecat"
    ]

    /// Whether `name` is an album directory.
    ///
    /// Excluded: the reserved siblings above (filesystem bookkeeping included),
    /// RevenueCat's directories and bundle-identifier-shaped names (SDK caches,
    /// with or without a hiding dot in front). Every other dot is
    /// allowed — a pre-encryption album is named whatever the user typed, and
    /// "Trip 2.0", "Nov. 2023" and ".secret" are all albums.
    public static func isAlbumDirectoryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if reservedNames.contains(lower) { return false }
        if reservedSubstrings.contains(where: { lower.contains($0) }) { return false }
        if isReverseDNSName(name) { return false }
        return true
    }

    /// Whether `name` is a bundle identifier — `com.vendor.thing`, the form
    /// SDK caches take, sometimes hidden as `.com.vendor.thing`: a known
    /// top-level domain followed by two or more labels from the
    /// bundle-identifier alphabet. Matching on the domain rather than the
    /// shape keeps "trip.to.paris" or "Mr.Mrs.Smith" as the album names they are.
    private static func isReverseDNSName(_ name: String) -> Bool {
        let labels = name.drop(while: { $0 == "." })
            .split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, topLevelDomains.contains(String(labels[0])) else { return false }
        return labels.allSatisfy(isBundleIdentifierLabel)
    }

    /// The domains bundle identifiers are published under. RevenueCat's cache
    /// is `me.freas.…`; the rest are the ones SDK vendors use.
    private static let topLevelDomains: Set<String> = [
        "com", "net", "org", "io", "me", "co", "dev", "app"
    ]

    private static let bundleIdentifierLabelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )

    private static func isBundleIdentifierLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.unicodeScalars.allSatisfy(bundleIdentifierLabelCharacters.contains)
    }
}
