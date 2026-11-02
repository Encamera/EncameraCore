//
//  BlobMigrationKeyCache.swift
//  EncameraCore
//
//  The keys the iCloud Drive blob migration runs on, held in memory for the
//  life of the process: each album's key, which opens its migration plan, and
//  the key library, which proves the key whose fingerprint an upload is stamped
//  with. They are read from the keychain only while the phone is unlocked, when a
//  pass or background task run starts, and kept across a lock, so a background task run that
//  resumes a suspended process can still move ciphertext-only items while the
//  phone is locked. Locking the app (`AuthManager.deauthorize()`) does not clear
//  them; an erase does (`clear()`).
//
//  The keychain items stay `kSecAttrAccessibleWhenUnlocked`. Relaxing them to
//  `AfterFirstUnlock` would let a cold-launched locked background task run read the keys, but
//  it would also hand the keys to a forensic extraction of any locked phone
//  unlocked since boot. The media files' default protection class already
//  leaves the ciphertext exposed to such an extraction, so the keychain setting
//  is what protects the vault.
//

import Foundation

@MainActor
public final class BlobMigrationKeyCache: DebugPrintable {

    /// The cache every production pass and background task run uses.
    public static let shared = BlobMigrationKeyCache()

    /// The CloudKit albums with an iCloud Drive migration plan, by `albumID`,
    /// each carrying its key.
    private var albums: [String: Album] = [:]
    /// The key library as it was read at the last refresh.
    public private(set) var storedKeys: [PrivateKey] = []

    public init() {}

    /// Whether any album's keys are held.
    public var hasKeys: Bool { !albums.isEmpty }

    /// The CloudKit album `albumID` with its key, when held.
    public func album(forAlbumID albumID: String) -> Album? {
        albums[albumID]
    }

    /// The ids of the albums whose keys are held, sorted.
    public var albumIDs: [String] { albums.keys.sorted() }

    /// Drops every album and key held.
    public func clear() {
        albums = [:]
        storedKeys = []
        printDebug("cleared")
    }

    /// Reads the keys from the keychain for every CloudKit album on this device
    /// with an iCloud Drive migration plan, replacing what was held. Call only
    /// while protected data is available: a locked keychain read fails, and the
    /// keys held already are kept.
    public func refreshKeysFromKeychain(using albumManager: AlbumManaging) {
        let pendingAlbumIDs = Set(CloudKitAlbumMarker.all().map(\.albumID)
            .filter { MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: $0) })
        guard let keys = try? albumManager.keyManager.storedKeys() else {
            printDebug("refresh skipped — the key library did not read")
            return
        }
        var refreshed: [String: Album] = [:]
        if !pendingAlbumIDs.isEmpty {
            for album in albumManager.fetchAlbumsFromSources(includingHidden: true)
            where album.storageOption == .cloudKit {
                guard let albumID = album.albumID, pendingAlbumIDs.contains(albumID) else { continue }
                refreshed[albumID] = album
            }
        }
        albums = refreshed
        storedKeys = keys
        printDebug("refresh albums=\(refreshed.count) keys=\(keys.count)")
    }
}
