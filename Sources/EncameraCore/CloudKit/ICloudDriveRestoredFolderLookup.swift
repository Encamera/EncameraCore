//
//  ICloudDriveRestoredFolderLookup.swift
//  EncameraCore
//
//  Finds the iCloud Drive folder an iCloud Drive album migration
//  (`ICloudDriveAlbumMigration.run(folder:)`) would move into a CloudKit album,
//  and whether that folder holds any media. A CloudKit album whose files were
//  put back into iCloud Drive after its upgrade finished has such a folder.
//
//  The folder is, in order, the first that holds media of:
//
//  1. the folder the album's `album.json` links
//     (`CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:)`);
//  2. a folder whose marker file names the album;
//  3. a folder with no marker whose name decrypts under the album's key to the
//     album's name, and which `CloudKitAlbumMarker.albumID(matching:)` resolves
//     to this album. That is the album `resolveCloudKitAlbumID` gives such a
//     folder, so it is the album a run for the folder joins.
//
//  A folder whose marker is evicted, in conflict, unreadable or names another
//  album is never the album's, and nor is any folder of an album in
//  `DeletedCloudKitAlbums`. A folder whose name is not `Album_` ciphertext is
//  never matched by name: the album list keys such a folder with the current
//  key, which this lookup does not read.
//
//  A folder holds media when the folder scanner's listing
//  (`ICloudDriveFolderScanner.listComponents`) finds a `<mediaID>.<ext>` file
//  in it, downloaded or as its iCloud placeholder. Nothing is downloaded, no
//  file's contents are read, and the only key used is the album's own.
//
//  The lookup writes nothing: not the folder, the marker, `album.json`, the
//  index or the plan. Markers are read through `ICloudDriveFolderMarkerCache`,
//  whose only writes are to its own memory. Listing a ubiquity container can
//  block behind the File Provider, so every entry point is a nonisolated async
//  function, which runs off the caller's actor.
//

import Foundation

public enum ICloudDriveRestoredFolderLookup {

    /// The iCloud Drive folder holding media that a migration would move into
    /// `cloudKitAlbum`, or nil when there is none, the album is not a CloudKit
    /// album, or this device has no iCloud Drive. Gathers the folder list, the
    /// deleted album ids and the marker cache from `albumManager`.
    ///
    /// Safe to call from the main actor: it runs off it.
    public nonisolated static func folderHoldingMedia(for cloudKitAlbum: Album,
                                                      albumManager: AlbumManaging) async -> URL? {
        guard ICloudDriveAlbumMigration.MigrationDeviceConditions.deviceHasICloudDrive() else { return nil }
        let albumFolders: [URL]
        let deletedAlbumIDs: Set<String>
        let markerCache: ICloudDriveFolderMarkerCache
        if let manager = albumManager as? AlbumManager {
            albumFolders = manager.listICloudDriveAlbumFolders()
            deletedAlbumIDs = manager.iCloudDriveAlbumDeletion.deletedAlbums.all()
            markerCache = manager.iCloudDriveFolderMarkers
        } else {
            albumFolders = ICloudDriveAlbumFolderWalk.albumFolders()
            deletedAlbumIDs = DeletedCloudKitAlbums().all()
            markerCache = ICloudDriveFolderMarkerCache()
        }
        return await folderHoldingMedia(for: cloudKitAlbum,
                                        albumFolders: albumFolders,
                                        deletedAlbumIDs: deletedAlbumIDs,
                                        markerCache: markerCache)
    }

    /// The first folder holding media that a migration would move into
    /// `cloudKitAlbum`: its linked folder, then one of `albumFolders` whose
    /// marker names it, then one of `albumFolders` with no marker that has its
    /// name under its key. Nil when none holds media.
    ///
    /// - Parameters:
    ///   - albumFolders: the iCloud Drive album folders, as
    ///     `ICloudDriveAlbumFolderWalk.albumFolders()` lists them.
    ///   - deletedAlbumIDs: the albums deleted on this device
    ///     (`DeletedCloudKitAlbums`).
    ///   - markerCache: where each folder's marker is read from, and read into
    ///     when it has no current reading.
    ///   - hasICloudDrive: whether this device has iCloud Drive. Checked before
    ///     anything in the container is read.
    ///   - linkedFolder: the folder an album's `album.json` links.
    nonisolated static func folderHoldingMedia(
        for cloudKitAlbum: Album,
        albumFolders: [URL],
        deletedAlbumIDs: Set<String>,
        markerCache: ICloudDriveFolderMarkerCache,
        hasICloudDrive: () -> Bool = ICloudDriveAlbumMigration.MigrationDeviceConditions.deviceHasICloudDrive,
        linkedFolder: (String) -> URL? = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:)
    ) async -> URL? {
        guard hasICloudDrive(),
              cloudKitAlbum.storageOption == .cloudKit,
              let albumID = cloudKitAlbum.albumID,
              !deletedAlbumIDs.contains(albumID) else { return nil }

        let linked = linkedFolder(albumID)
        if let linked,
           isLinkedFolderOfAlbum(albumID, marker: currentMarker(of: linked, in: markerCache)),
           holdsMedia(linked) {
            return linked
        }

        var markerless: [URL] = []
        for folder in albumFolders where !isSameFolder(folder, linked) {
            switch currentMarker(of: folder, in: markerCache) {
            case .present(let marker) where marker.albumID == albumID:
                if holdsMedia(folder) { return folder }
            case .absent:
                markerless.append(folder)
            case .present, .evicted, .conflicted, .unreadable:
                continue
            }
        }
        return markerless.first { folder in
            isNamedFolderOfAlbum(folder, cloudKitAlbum: cloudKitAlbum, albumID: albumID) && holdsMedia(folder)
        }
    }

    /// Whether the linked folder whose marker reads `marker` is still the album's:
    /// its marker names the album, or it has none.
    private static func isLinkedFolderOfAlbum(_ albumID: String,
                                              marker: ICloudDriveAlbumMarkerFile.ReadResult) -> Bool {
        switch marker {
        case .present(let present): return present.albumID == albumID
        case .absent: return true
        case .evicted, .conflicted, .unreadable: return false
        }
    }

    /// Whether a run for the marker-less `folder` resolves to `albumID`: the
    /// folder's name decrypts under the album's key to the album's name, and
    /// `CloudKitAlbumMarker.albumID(matching:)`, the first resolution
    /// `resolveCloudKitAlbumID` tries, picks this album for it.
    private static func isNamedFolderOfAlbum(_ folder: URL, cloudKitAlbum: Album, albumID: String) -> Bool {
        let folderName = folder.lastPathComponent
        guard Album.decryptedAlbumName(folderName, key: cloudKitAlbum.key) == cloudKitAlbum.name else { return false }
        let folderAlbum = Album(encryptedName: folderName, storageOption: .icloud,
                                creationDate: cloudKitAlbum.creationDate, key: cloudKitAlbum.key)
        return CloudKitAlbumMarker.albumID(matching: folderAlbum) == albumID
    }

    /// `folder`'s marker: the cached reading while it is current, else one read now.
    private static func currentMarker(of folder: URL,
                                      in markerCache: ICloudDriveFolderMarkerCache) -> ICloudDriveAlbumMarkerFile.ReadResult {
        if let lookup = markerCache.lookup(folder), lookup.isCurrent {
            return lookup.reading.marker
        }
        return markerCache.readNow(folder).marker
    }

    /// Whether `folder` holds a media file in either form. A folder that cannot
    /// be listed holds none.
    private static func holdsMedia(_ folder: URL) -> Bool {
        guard let components = try? ICloudDriveFolderScanner.listComponents(in: folder) else { return false }
        return !components.isEmpty
    }

    private static func isSameFolder(_ folder: URL, _ other: URL?) -> Bool {
        guard let other else { return false }
        return folder.standardizedFileURL.resolvingSymlinksInPath().path
            == other.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
