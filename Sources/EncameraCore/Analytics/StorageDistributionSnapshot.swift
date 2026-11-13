//
//  StorageDistributionSnapshot.swift
//  EncameraCore
//
//  Where this device's albums live and how much media sits on each storage
//  type. Built once per launch after unlock and reported to the visitor
//  profile, so every input is injected and the classification runs with no
//  keychain or disk access.
//
//  Albums can live on iCloud Drive, locally or in CloudKit. The pending
//  migration plan count is reported as zero: the background CloudKit
//  migration keeps no per-album plan files, and an album still on iCloud
//  Drive next to CloudKit albums already reads as `in_progress`.
//

import Foundation

public struct StorageDistributionSnapshot: Equatable, Sendable {

    /// The migration stage reported on the profile, highest precedence first
    /// when several devices of one visitor disagree.
    public enum MigrationStage: String, CaseIterable, Sendable {
        case inProgress = "in_progress"
        case notStarted = "not_started"
        case completed = "completed"
        case nativeCloudKit = "native_cloudkit"
        case localOnly = "local_only"
        case noAlbums = "no_albums"
    }

    /// Album counts per storage type, including hidden albums.
    public let albumsICloud: Int
    public let albumsLocal: Int
    public let albumsCloudKit: Int
    /// Media items per storage type.
    public let mediaICloud: Int
    public let mediaLocal: Int
    public let mediaCloudKit: Int
    public let albumsLocked: Int
    /// Sorted, `+`-joined set of storage types holding at least one album, or
    /// `none`.
    public let storageMix: String
    public let migrationStage: MigrationStage
    public let migrationPlansPending: Int
    public let isCloudKitAvailable: Bool
    public let migrationPromptDismissed: Bool
    public let defaultStorage: StorageType

    public init(
        albumsICloud: Int,
        albumsLocal: Int,
        albumsCloudKit: Int,
        mediaICloud: Int,
        mediaLocal: Int,
        mediaCloudKit: Int,
        albumsLocked: Int,
        storageMix: String,
        migrationStage: MigrationStage,
        migrationPlansPending: Int,
        isCloudKitAvailable: Bool,
        migrationPromptDismissed: Bool,
        defaultStorage: StorageType
    ) {
        self.albumsICloud = albumsICloud
        self.albumsLocal = albumsLocal
        self.albumsCloudKit = albumsCloudKit
        self.mediaICloud = mediaICloud
        self.mediaLocal = mediaLocal
        self.mediaCloudKit = mediaCloudKit
        self.albumsLocked = albumsLocked
        self.storageMix = storageMix
        self.migrationStage = migrationStage
        self.migrationPlansPending = migrationPlansPending
        self.isCloudKitAvailable = isCloudKitAvailable
        self.migrationPromptDismissed = migrationPromptDismissed
        self.defaultStorage = defaultStorage
    }

    /// The profile's lowercase token for a storage type. Shared by `storageMix`
    /// and `defaultStorageToken` so the backend has one vocabulary.
    public static func storageToken(_ type: StorageType) -> String {
        switch type {
        case .icloud: return "icloud"
        case .local: return "local"
        case .cloudKit: return "cloudkit"
        }
    }

    public var defaultStorageToken: String {
        Self.storageToken(defaultStorage)
    }

    /// Classifies the device's albums.
    ///
    /// - Parameters:
    ///   - albums: Every album on this device, hidden ones included.
    ///   - lockedAlbums: Placeholders for albums whose key is not on this
    ///     device. Counted per storage type, with no media.
    ///   - mediaCount: The media item count of an album.
    ///   - hasHadICloudDriveAlbums: Whether this device has seen an iCloud
    ///     Drive album before. Tells `completed` apart from `native_cloudkit`.
    public static func build(
        albums: [Album],
        lockedAlbums: [StorageType] = [],
        mediaCount: (Album) -> Int,
        defaultStorage: StorageType,
        hasHadICloudDriveAlbums: Bool = false,
        isCloudKitAvailable: Bool = false,
        migrationPromptDismissed: Bool = false
    ) -> StorageDistributionSnapshot {
        var albumCounts: [StorageType: Int] = [:]
        var mediaCounts: [StorageType: Int] = [:]
        for album in albums {
            albumCounts[album.storageOption, default: 0] += 1
            mediaCounts[album.storageOption, default: 0] += mediaCount(album)
        }
        for storage in lockedAlbums {
            albumCounts[storage, default: 0] += 1
        }

        let albumsICloud = albumCounts[.icloud] ?? 0
        let albumsLocal = albumCounts[.local] ?? 0
        let albumsCloudKit = albumCounts[.cloudKit] ?? 0

        return StorageDistributionSnapshot(
            albumsICloud: albumsICloud,
            albumsLocal: albumsLocal,
            albumsCloudKit: albumsCloudKit,
            mediaICloud: mediaCounts[.icloud] ?? 0,
            mediaLocal: mediaCounts[.local] ?? 0,
            mediaCloudKit: mediaCounts[.cloudKit] ?? 0,
            albumsLocked: lockedAlbums.count,
            storageMix: storageMix(albumCounts: albumCounts),
            migrationStage: migrationStage(
                albumsICloud: albumsICloud,
                albumsLocal: albumsLocal,
                albumsCloudKit: albumsCloudKit,
                hasHadICloudDriveAlbums: hasHadICloudDriveAlbums || albumsICloud > 0
            ),
            migrationPlansPending: 0,
            isCloudKitAvailable: isCloudKitAvailable,
            migrationPromptDismissed: migrationPromptDismissed,
            defaultStorage: defaultStorage
        )
    }

    static func storageMix(albumCounts: [StorageType: Int]) -> String {
        let tokens = albumCounts
            .filter { $0.value > 0 }
            .map { storageToken($0.key) }
            .sorted()
        return tokens.isEmpty ? "none" : tokens.joined(separator: "+")
    }

    static func migrationStage(
        albumsICloud: Int,
        albumsLocal: Int,
        albumsCloudKit: Int = 0,
        hasHadICloudDriveAlbums: Bool = false
    ) -> MigrationStage {
        if albumsICloud + albumsLocal + albumsCloudKit == 0 {
            return .noAlbums
        }
        if albumsICloud > 0 {
            return albumsCloudKit > 0 ? .inProgress : .notStarted
        }
        if albumsCloudKit > 0 {
            return hasHadICloudDriveAlbums ? .completed : .nativeCloudKit
        }
        return .localOnly
    }
}
