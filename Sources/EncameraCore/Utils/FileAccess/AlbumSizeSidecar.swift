//
//  AlbumSizeSidecar.swift
//  EncameraCore
//
//  Per-album component sizes, so "how many bytes does this album hold in iCloud"
//  is answerable offline and instantly. CloudKit sync writes the sizes of
//  `.cloudKit` components from record metadata; the iCloud Drive folder scanner
//  writes the sizes of `.iCloudDrive` components from file metadata. See
//  `Documentation/storage-accounting-model.md` for why this is a sidecar rather
//  than a field on `MediaIndexEntry`.
//

import Foundation
import CryptoKit

/// Byte sizes for one album's media components, keyed by **record name**
/// (`mediaID#<mediaTypeRawValue>`), wherever each component lives.
///
/// One key per component, so a component counts once whichever side holds it:
/// when it moves from iCloud Drive to CloudKit, the sync's size replaces the
/// scanner's under the same key. Which side owns a size is not stored here; it is
/// the component's location in the album's media index, and each writer passes
/// the index entries to `apply(updates:removals:owner:entries:)` so it never
/// writes or removes the other side's sizes.
///
/// Keyed by record name and not `mediaID` because a Live Photo is two CloudKit
/// records with two sizes that collapse into a single `MediaIndexEntry`; keying by
/// `mediaID` would let one component silently overwrite the other's size.
///
/// A derived cache, like the media index it sits beside: it lives in the local,
/// never-synced `MediaIndex` directory, is excluded from backup, and a loss of it
/// costs a resync rather than data. Contents are record names and integers — both
/// already exist in plaintext as CloudKit record names — so the file is not
/// encrypted; the album name never appears in it, and the filename is a hash.
public actor AlbumSizeSidecar {

    /// The on-disk shape. Versioned so a later field can be added without the
    /// unreadable-file fallback firing on every album.
    private struct Payload: Codable {
        var version: Int = 1
        var sizes: [String: Int64]
    }

    private let fileURL: URL
    private var sizes: [String: Int64]
    /// Whether the album has a sidecar on disk at all, which is what distinguishes
    /// "never captured" from "captured and genuinely empty" for the storage screen.
    private var loadedFromDisk: Bool

    /// The sidecar file for an album, named by the same SHA-256 hash of the album id
    /// that `MediaIndexStore.indexURL(for:)` uses, so no cleartext album name
    /// reaches disk.
    public static func sidecarURL(for album: Album) -> URL {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return MediaIndexStore.indexDirectoryURL().appendingPathComponent("\(hash).encsizes")
    }

    public init(album: Album) {
        self.init(fileURL: Self.sidecarURL(for: album))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            self.sizes = decoded.sizes
            self.loadedFromDisk = true
        } else {
            self.sizes = [:]
            self.loadedFromDisk = false
        }
    }

    // MARK: - Read

    /// Total bytes this album occupies in CloudKit, summed over every record.
    public func totalBytes() -> Int64 {
        sizes.values.reduce(0, +)
    }

    /// How many records have a recorded size.
    public func recordCount() -> Int {
        sizes.count
    }

    public func bytes(forRecordName recordName: String) -> Int64? {
        sizes[recordName]
    }

    /// Every record's size, keyed by record name. The record name carries the
    /// component's media type, so this is what a per-type breakdown reads.
    public func sizesByRecordName() -> [String: Int64] {
        sizes
    }

    /// The album's byte totals over the components in `entries`, the album's
    /// index. A component with no recorded size counts as zero. An `.iCloudDrive`
    /// component named in `deferred` (record names) has its move deferred, so it
    /// counts as deferred rather than remaining.
    public func mediaBytes(for entries: [MediaIndexEntry], deferred: Set<String> = []) -> AlbumMediaBytes {
        var remaining: Int64 = 0
        var deferredBytes: Int64 = 0
        var total: Int64 = 0
        for (recordName, location) in entries.componentLocations() {
            guard let bytes = sizes[recordName] else { continue }
            total += bytes
            guard location == .iCloudDrive else { continue }
            if deferred.contains(recordName) {
                deferredBytes += bytes
            } else {
                remaining += bytes
            }
        }
        return AlbumMediaBytes(remainingOnICloudDrive: remaining, total: total, deferredOnICloudDrive: deferredBytes)
    }

    /// True when a sidecar file existed when this instance loaded. A file that
    /// exists and records nothing is a genuinely empty album; no file at all is an
    /// album that has never been measured.
    public func existsOnDisk() -> Bool {
        loadedFromDisk
    }

    // MARK: - Write

    /// Merges `updates` in, drops `removals`, and persists once, limited to the
    /// sizes `owner` owns: a key whose component `entries` places at the other
    /// location is neither written nor removed. A key with no component in
    /// `entries` is open to either owner, so a component that has just been
    /// removed from the index can drop its size.
    ///
    /// Merge rather than wholesale replacement: the sync path applies a *delta*, so
    /// overwriting with only the changed records would zero every record the feed
    /// did not mention. The single write at the end matches the index's own
    /// save-once-per-sync durability shape.
    public func apply(updates: [String: Int64],
                      removals: Set<String>,
                      owner: MediaComponentLocation,
                      entries: [MediaIndexEntry]) throws {
        let locations = entries.componentLocations()
        let ownedByOther = { (recordName: String) -> Bool in
            locations[recordName].map { $0 != owner } ?? false
        }
        let ownedUpdates = updates.filter { !ownedByOther($0.key) }
        let ownedRemovals = removals.filter { !ownedByOther($0) }
        guard !ownedUpdates.isEmpty || !ownedRemovals.isEmpty else { return }
        var merged = sizes
        for (recordName, bytes) in ownedUpdates {
            merged[recordName] = max(0, bytes)
        }
        for recordName in ownedRemovals {
            merged[recordName] = nil
        }
        try commit(merged)
    }

    /// Replaces the whole map.
    public func replace(with newSizes: [String: Int64]) throws {
        try commit(newSizes.mapValues { max(0, $0) })
    }

    public func removeAll() throws {
        try commit([:])
    }

    /// Persists first and adopts second, so a failed write leaves the in-memory map
    /// exactly as it was on disk. Keeping an unpersisted mutation would make
    /// `totalBytes()` report a figure that disappears on relaunch — the same reason
    /// `MediaIndexStore` rolls its warm cache back after a save failure.
    private func commit(_ newSizes: [String: Int64]) throws {
        let data = try JSONEncoder().encode(Payload(sizes: newSizes))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        excludeFromBackup()
        sizes = newSizes
        loadedFromDisk = true
    }

    private func excludeFromBackup() {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// One album's media bytes, split by where each component lives.
public struct AlbumMediaBytes: Equatable, Sendable {
    /// Bytes of the components still on iCloud Drive, waiting to move to CloudKit.
    /// Deferred components are not counted.
    public let remainingOnICloudDrive: Int64
    /// Bytes of every component, on either side, each counted once.
    public let total: Int64
    /// Bytes of the components on iCloud Drive whose move is deferred.
    public let deferredOnICloudDrive: Int64

    public init(remainingOnICloudDrive: Int64, total: Int64, deferredOnICloudDrive: Int64 = 0) {
        self.remainingOnICloudDrive = remainingOnICloudDrive
        self.total = total
        self.deferredOnICloudDrive = deferredOnICloudDrive
    }
}

private extension Array where Element == MediaIndexEntry {
    /// Each component's location, keyed by its record name.
    func componentLocations() -> [String: MediaComponentLocation] {
        var locations: [String: MediaComponentLocation] = [:]
        for entry in self {
            if entry.hasPhotoComponent {
                locations[MediaRecordName.componentRecordName(mediaID: entry.id, type: .photo)] = entry.photoLocation
            }
            if entry.hasVideoComponent {
                locations[MediaRecordName.componentRecordName(mediaID: entry.id, type: .video)] = entry.videoLocation
            }
        }
        return locations
    }
}
