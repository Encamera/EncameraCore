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
//  It also links the album to its iCloud Drive folder when it has one: the
//  folder that still holds the album's media not yet moved to CloudKit. The link
//  is this device's own and never reaches the album record.
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
    /// The fields the pending local change touched. Nil on a dirty marker means
    /// every field, as for a marker written dirty whole (a new or moved-in album).
    /// A remote change to any other field is still applied while the marker is dirty.
    public var dirtyFields: Set<Field>?
    /// The album's iCloud Drive folder, as a path relative to the iCloud Drive
    /// root (`albums/<folder>`, or `<folder>` for an album still in the root
    /// layout). Nil when the album has no linked folder. Relative because the
    /// container's absolute path is not stable across launches and devices.
    ///
    /// The folder name is whatever the folder is called on iCloud Drive: the
    /// ciphertext `Album_` form, or the plaintext name of an album created before
    /// album-name encryption. Not a record field, so `fields(differingFrom:)`
    /// ignores it and setting it marks nothing dirty.
    public var iCloudDriveFolderPath: String?

    /// The record fields `album.json` mirrors.
    public enum Field: String, Codable, CaseIterable, Sendable {
        case name, hidden, cover
    }

    public init(encName: String,
                createdAt: Date,
                isHidden: Bool = false,
                coverMediaID: String? = nil,
                keyFingerprint: String? = nil,
                dirty: Bool = false,
                dirtyFields: Set<Field>? = nil,
                iCloudDriveFolderPath: String? = nil) {
        self.encName = encName
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.coverMediaID = coverMediaID
        self.keyFingerprint = keyFingerprint
        self.dirty = dirty
        self.dirtyFields = dirtyFields
        self.iCloudDriveFolderPath = iCloudDriveFolderPath
    }

    /// The marker for a CloudKit album as this device currently knows it.
    public init(album: Album, isHidden: Bool, coverMediaID: String? = nil, dirty: Bool = false) {
        self.init(encName: album.encryptedPathComponent,
                  createdAt: album.creationDate,
                  isHidden: isHidden,
                  coverMediaID: coverMediaID,
                  keyFingerprint: album.key.keyFingerprint,
                  dirty: dirty)
    }

    static let fileName = "album.json"

    /// The `coverMediaID` of an album whose cover the user turned off, as opposed to
    /// nil, which means the album picks its own cover.
    public static let disabledCoverID = "none"

    /// The fields a local change has not yet saved to the record: none on a clean
    /// marker, every field on a dirty marker that does not say which.
    public var pendingFields: Set<Field> {
        guard dirty else { return [] }
        return dirtyFields ?? Set(Field.allCases)
    }

    /// The fields whose values differ between `self` and `other`.
    public func fields(differingFrom other: CloudKitAlbumMarker) -> Set<Field> {
        var fields: Set<Field> = []
        if encName != other.encName || keyFingerprint != other.keyFingerprint { fields.insert(.name) }
        if isHidden != other.isHidden { fields.insert(.hidden) }
        if coverMediaID != other.coverMediaID { fields.insert(.cover) }
        return fields
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

    // MARK: - iCloud Drive folder link

    /// `folder`'s path relative to `root`, or nil when `folder` is not inside it.
    public static func iCloudDriveFolderPath(for folder: URL,
                                             relativeTo root: URL = iCloudStorageModel.rootURL) -> String? {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folderComponents = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard folderComponents.count > rootComponents.count,
              Array(folderComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return folderComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// The linked iCloud Drive folder under `root`, or nil when the album has no
    /// link. The folder is not checked for existence.
    public func linkedICloudDriveFolderURL(relativeTo root: URL = iCloudStorageModel.rootURL) -> URL? {
        guard let iCloudDriveFolderPath, !iCloudDriveFolderPath.isEmpty else { return nil }
        return root.appendingPathComponent(iCloudDriveFolderPath, isDirectory: true)
    }

    /// Links the marker to `folder`. Returns false, changing nothing, when
    /// `folder` is not inside `root`.
    @discardableResult
    public mutating func linkICloudDriveFolder(_ folder: URL,
                                               relativeTo root: URL = iCloudStorageModel.rootURL) -> Bool {
        guard let path = Self.iCloudDriveFolderPath(for: folder, relativeTo: root) else { return false }
        iCloudDriveFolderPath = path
        return true
    }

    /// The iCloud Drive folder the album `albumID` is linked to on this device, or
    /// nil when it has no marker or no link. iCloud Drive is unavailable when the
    /// container cannot be reached, so callers check the folder exists.
    public static func linkedICloudDriveFolderURL(albumID: String) -> URL? {
        guard iCloudStorageModel.isRootAvailable else { return nil }
        return read(albumID: albumID)?.linkedICloudDriveFolderURL()
    }

    /// The id of the CloudKit album on this device whose `album.json` links the
    /// iCloud Drive folder `folder`, or nil when none does.
    public static func albumID(linkingICloudDriveFolder folder: URL) -> String? {
        guard iCloudStorageModel.isRootAvailable,
              let path = iCloudDriveFolderPath(for: folder) else { return nil }
        return all().first { $0.marker.iCloudDriveFolderPath == path }?.albumID
    }

    /// Links the album `albumID`'s marker to `folder` and writes it, leaving
    /// `dirty` alone: the link is not on the album record.
    ///
    /// - Returns: whether `album.json` was written. False when the album has no
    ///   marker on this device, `folder` is outside the iCloud Drive root, or the
    ///   marker already links `folder`.
    @discardableResult
    public static func linkICloudDriveFolder(_ folder: URL,
                                             albumID: String,
                                             relativeTo root: URL = iCloudStorageModel.rootURL) throws -> Bool {
        guard var marker = read(albumID: albumID) else { return false }
        let before = marker.iCloudDriveFolderPath
        guard marker.linkICloudDriveFolder(folder, relativeTo: root),
              marker.iCloudDriveFolderPath != before else { return false }
        try marker.write(albumID: albumID)
        return true
    }

    /// Drops the album `albumID`'s link to its iCloud Drive folder and writes the
    /// marker, leaving `dirty` alone.
    ///
    /// - Returns: whether `album.json` was written. False when the album has no
    ///   marker on this device or no link.
    @discardableResult
    public static func unlinkICloudDriveFolder(albumID: String) throws -> Bool {
        guard var marker = read(albumID: albumID), marker.iCloudDriveFolderPath != nil else { return false }
        marker.iCloudDriveFolderPath = nil
        try marker.write(albumID: albumID)
        return true
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
        clean.dirtyFields = nil
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
