//
//  CloudKitAlbumMarker.swift
//  EncameraCore
//
//  The on-device record of a CloudKit album: `<albumID>/album.json` under
//  `CloudKitAlbumMarker.rootDirectoryURL` in Application Support. Its presence is
//  what makes a CloudKit album discoverable here, and it carries what the album
//  list needs to show the album offline. The name is only ever stored as
//  ciphertext (`encName`).
//

import Foundation

public struct CloudKitAlbumMarker: Codable, Equatable, Sendable {

    /// The album name encrypted under the album key, in the `Album_` directory-name
    /// form. The same value the `EncAlbum` record carries.
    public var encName: String
    public var createdAt: Date
    public var isHidden: Bool
    public var coverMediaID: String?
    /// The keychain label of the key that encrypts `encName` — an ordering hint for
    /// key discovery, never proof.
    public var keyFingerprint: String?
    /// Set while a local change has not yet been saved to the album record.
    public var dirty: Bool

    public init(encName: String,
                createdAt: Date,
                isHidden: Bool = false,
                coverMediaID: String? = nil,
                keyFingerprint: String? = nil,
                dirty: Bool = false) {
        self.encName = encName
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.coverMediaID = coverMediaID
        self.keyFingerprint = keyFingerprint
        self.dirty = dirty
    }

    /// The marker for a CloudKit album as this device currently knows it.
    public init(album: Album, isHidden: Bool, coverMediaID: String? = nil, dirty: Bool = false) {
        self.init(encName: album.encryptedPathComponent,
                  createdAt: album.creationDate,
                  isHidden: isHidden,
                  coverMediaID: coverMediaID,
                  keyFingerprint: album.key.keychainLabel,
                  dirty: dirty)
    }

    static let fileName = "album.json"

    /// The `coverMediaID` of an album whose cover the user turned off, as opposed to
    /// nil, which means the album picks its own cover.
    public static let disabledCoverID = "none"

    /// The cover the album record carries. The record references a media record, so
    /// a disabled cover goes as no cover; it stays disabled on this device only.
    public var recordCoverMediaID: String? {
        coverMediaID == Self.disabledCoverID ? nil : coverMediaID
    }

    /// Characters an album id keeps verbatim in its directory name. A UUID is
    /// entirely within this set; anything else (a base64 record name can hold `/`,
    /// `+` and `=`) is percent-encoded so every id maps to exactly one directory.
    private static let directoryNameCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert("-")
        return set
    }()

    static func directoryName(forAlbumID albumID: String) -> String {
        albumID.addingPercentEncoding(withAllowedCharacters: directoryNameCharacters) ?? albumID
    }

    static func albumID(forDirectoryName name: String) -> String? {
        name.removingPercentEncoding
    }

    // MARK: - Location

    /// Where markers live: Application Support, never Caches. A marker is the only
    /// record of an album that has not been published yet, and it holds changes not
    /// yet saved to the album record (a rename, the hidden flag, a disabled cover),
    /// so it must survive the OS purging caches.
    ///
    /// Included in the device backup, like the upload queue (`CloudKitUploadQueue`):
    /// a restored queue holds captures for albums that may exist only as a marker, and
    /// without the marker no coordinator is ever built for them. A marker holds the
    /// name only as ciphertext.
    public static var rootDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudKitAlbums", isDirectory: true)
    }

    public static func directoryURL(albumID: String) -> URL {
        rootDirectoryURL
            .appendingPathComponent(directoryName(forAlbumID: albumID), isDirectory: true)
    }

    public static func fileURL(albumID: String) -> URL {
        directoryURL(albumID: albumID).appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Read / write

    public static func read(albumID: String) -> CloudKitAlbumMarker? {
        guard let data = try? Data(contentsOf: fileURL(albumID: albumID)) else { return nil }
        return try? JSONDecoder().decode(CloudKitAlbumMarker.self, from: data)
    }

    public static func exists(albumID: String) -> Bool {
        read(albumID: albumID) != nil
    }

    /// Writes the marker atomically, creating its directory.
    public func write(albumID: String) throws {
        let directory = Self.directoryURL(albumID: albumID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL(albumID: albumID), options: .atomic)
    }

    /// Clears `dirty` on the album's marker once the record was saved from `pushed`,
    /// unless the marker changed while the save was in flight: a newer change still
    /// needs saving, so it stays dirty.
    public static func clearDirty(albumID: String, ifUnchangedFrom pushed: CloudKitAlbumMarker) throws {
        guard pushed.dirty, read(albumID: albumID) == pushed else { return }
        var clean = pushed
        clean.dirty = false
        try clean.write(albumID: albumID)
    }

    /// Removes the album's marker directory. Removing one that is not there is not
    /// an error.
    public static func remove(albumID: String) throws {
        let directory = directoryURL(albumID: albumID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Enumeration

    /// Every CloudKit album marker on this device, keyed by album id. A directory
    /// without a readable `album.json` is not an album.
    public static func all() -> [(albumID: String, marker: CloudKitAlbumMarker)] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let albumID = albumID(forDirectoryName: url.lastPathComponent),
                  let marker = read(albumID: albumID) else { return nil }
            return (albumID, marker)
        }
    }

    /// The id of the CloudKit album on this device whose `encName` decrypts under
    /// `album`'s key to `album`'s name — the CloudKit counterpart of a local or
    /// iCloud Drive album, if it has one.
    public static func albumID(matching album: Album) -> String? {
        all().first { entry in
            Album.decryptedAlbumName(entry.marker.encName, key: album.key) == album.name
        }?.albumID
    }
}
