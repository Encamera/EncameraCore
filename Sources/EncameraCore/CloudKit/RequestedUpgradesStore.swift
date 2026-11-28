//
//  RequestedUpgradesStore.swift
//  EncameraCore
//
//  The albums the user asked to upgrade from iCloud Drive to CloudKit, on disk:
//  `CloudKitMigration/ICloudDriveAlbums/requested-upgrades.json`, beside the
//  per-album plan directories. It is `ICloudDriveUpgradeScheduler`'s
//  `SchedulerState.order` and nothing else reads or writes it.
//
//  The file is plain JSON, `{ "version": 1, "albumIDs": ["<uuid>", …] }`, first
//  in first out. It holds CloudKit album ids only, which are random UUIDs: no
//  name, path or key. It is not encrypted and has the default protection class,
//  so it reads without a key and while the phone is locked.
//
//  A missing file, one that does not decode and one of another version all read
//  as an empty list. A save replaces the file atomically.
//

import Foundation

struct RequestedUpgradesStore {
    static let fileName = "requested-upgrades.json"
    /// The only version this build reads and the one it writes.
    static let currentVersion = 1

    private struct StoredList: Codable {
        let version: Int
        let albumIDs: [String]
    }

    private let directory: URL

    /// - Parameter directory: the directory the file lives in.
    init(directory: URL = MigrationPlanFileUtil.iCloudDriveAlbumsDirectory) {
        self.directory = directory
    }

    var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    /// The stored album ids in order, or none when there is no readable version
    /// 1 file.
    func loadAlbumIDs() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(StoredList.self, from: data),
              stored.version == Self.currentVersion else { return [] }
        return stored.albumIDs
    }

    /// Replaces the file with `albumIDs`, atomically.
    func saveAlbumIDs(_ albumIDs: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StoredList(version: Self.currentVersion, albumIDs: albumIDs))
        try data.write(to: fileURL, options: .atomic)
    }

    /// Removes the file. Removing one that is not there is not an error.
    func removeFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
