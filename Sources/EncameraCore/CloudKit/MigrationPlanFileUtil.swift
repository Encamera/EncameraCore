//
//  MigrationPlanFileUtil.swift
//  EncameraCore
//
//  The on-disk layout of migration plans and the file operations on it. Every
//  path under `CloudKitMigration/` is built here:
//
//      CloudKitMigration/<sha256(source Album.id)>/<planID>.encplan
//      CloudKitMigration/<sha256(source Album.id)>/album.destination
//      CloudKitMigration/ICloudDriveAlbums/<sha256("<albumID>_cloudKit")>/album.encplan
//
//  Nothing here decrypts a plan; `EncryptedPlanStore` reads and writes them.
//

import CryptoKit
import Foundation

enum MigrationPlanFileUtil {

    static let planExtension = "encplan"

    private static var fileManager: FileManager { .default }

    // MARK: Layout

    /// `~/Library/Application Support/CloudKitMigration/`: local, never synced,
    /// excluded from backup.
    static var rootDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("CloudKitMigration", isDirectory: true)
    }

    /// `CloudKitMigration/<sha256(albumID)>/`, the plans whose source is the album
    /// whose `Album.id` is `albumID`.
    static func sourceDirectory(albumID: String) -> URL {
        rootDirectory.appendingPathComponent(directoryName(albumID: albumID), isDirectory: true)
    }

    /// `CloudKitMigration/ICloudDriveAlbums/`, one directory per CloudKit album an
    /// iCloud Drive album migrates into.
    static var iCloudDriveAlbumsDirectory: URL {
        rootDirectory.appendingPathComponent("ICloudDriveAlbums", isDirectory: true)
    }

    /// `CloudKitMigration/ICloudDriveAlbums/<sha256("<cloudKitAlbumID>_cloudKit")>/`.
    static func iCloudDriveAlbumDirectory(cloudKitAlbumID: String) -> URL {
        let albumID = "\(cloudKitAlbumID)_\(StorageType.cloudKit.rawValue)"
        return iCloudDriveAlbumsDirectory.appendingPathComponent(directoryName(albumID: albumID), isDirectory: true)
    }

    /// The SHA-256 of `albumID`, hex: the name of the album's plan directory and the
    /// contents of a destination marker naming it.
    static func directoryName(albumID: String) -> String {
        SHA256.hash(data: Data(albumID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `<directory>/<planID>.encplan`.
    static func planURL(in directory: URL, planID: String) -> URL {
        directory.appendingPathComponent(planID).appendingPathExtension(planExtension)
    }

    /// `<directory>/album.encplan`, the album-scope plan.
    static func albumPlanURL(in directory: URL) -> URL {
        planURL(in: directory, planID: MigrationPlan.albumPlanID)
    }

    /// Whether `url` names an album-scope plan.
    static func isAlbumPlan(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent == MigrationPlan.albumPlanID
    }

    /// The file named `name` in the directory holding the plan at `planURL`.
    static func file(named name: String, besidePlanAt planURL: URL) -> URL {
        planURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// The plan at `url` moved into `directory`, keeping its file name.
    static func planURL(_ url: URL, movedTo directory: URL) -> URL {
        directory.appendingPathComponent(url.lastPathComponent)
    }

    // MARK: Queries

    static func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Whether `directory` holds an album-scope plan.
    static func hasAlbumPlan(in directory: URL) -> Bool {
        exists(albumPlanURL(in: directory))
    }

    /// The plan files in `directory`, sorted by name. Empty when it does not exist.
    static func planFiles(in directory: URL) -> [URL] {
        contents(of: directory)
            .filter { $0.pathExtension == planExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Everything in `directory`. Empty when it does not exist.
    static func contents(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: Writes

    /// Creates the directory that will hold the file at `url`.
    static func createDirectory(holding url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func remove(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    /// Removes `url` when it exists. A failed removal is ignored.
    static func removeIfPresent(_ url: URL) {
        guard exists(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Removes `directory` when it is empty.
    static func removeIfEmpty(_ directory: URL) {
        guard exists(directory), contents(of: directory).isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
