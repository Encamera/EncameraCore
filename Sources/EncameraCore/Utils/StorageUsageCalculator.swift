//
//  StorageUsageCalculator.swift
//  EncameraCore
//
//  The single entry point behind the Storage Insights screen: walks every root
//  Encamera writes to and returns a `StorageUsageBreakdown`, tabulated per album
//  and per media type. See `Documentation/storage-accounting-model.md` for what
//  each bucket means.
//

import Foundation
import CryptoKit

public actor StorageUsageCalculator: DebugPrintable {

    private let albumManager: AlbumManaging
    private let cache: CloudKitBlobCache
    private let driveSizing: ICloudDriveSizing
    private let thumbnailDirectory: URL
    private let indexDirectory: URL
    /// Test seam: production reads the real per-album sidecar, a fixture supplies its
    /// own so the walk can be exercised without an Application Support directory.
    private let makeSidecar: @Sendable (Album) -> AlbumSizeSidecar
    /// Test seam: how many media components the album's index holds. Decides whether
    /// a CloudKit album with no sidecar is genuinely empty or has never been measured.
    private let indexComponentCount: @Sendable (Album) async -> Int

    /// Whether the last run's disk walk executed on the main thread. Nothing in the
    /// app reads this; `StorageUsageCalculatorTests` does, because "does not block
    /// the UI" is the one property of this type that no output value can prove.
    private var lastRunTouchedMainThread = false

    /// - Parameter cache: always `CloudKitBlobCache.shared` in production. A second
    ///   instance would report a divergent snapshot of the same directory.
    public init(albumManager: AlbumManaging,
                cache: CloudKitBlobCache = .shared,
                driveSizing: ICloudDriveSizing = ICloudDriveSizer(),
                thumbnailDirectory: URL = MediaPreviewStorage.directory,
                indexDirectory: URL = MediaIndexStore.indexDirectoryURL(),
                makeSidecar: @escaping @Sendable (Album) -> AlbumSizeSidecar = { AlbumSizeSidecar(album: $0) },
                indexComponentCount: @escaping @Sendable (Album) async -> Int = { album in
                    let entries = await MediaIndexStore(album: album).current()?.entries ?? []
                    return entries.reduce(0) { $0 + ($1.hasPhotoComponent ? 1 : 0) + ($1.hasVideoComponent ? 1 : 0) }
                }) {
        self.albumManager = albumManager
        self.cache = cache
        self.driveSizing = driveSizing
        self.thumbnailDirectory = thumbnailDirectory
        self.indexDirectory = indexDirectory
        self.makeSidecar = makeSidecar
        self.indexComponentCount = indexComponentCount
    }

    /// Measures every bucket.
    ///
    /// Hidden albums are counted. Excluding them would make the total silently
    /// under-report on any device that has one, with no way for the user to tell why
    /// the arithmetic does not add up — and since the screen shows byte counts only,
    /// counting a hidden album reveals nothing about it.
    ///
    /// - Throws: `CancellationError` when the caller walks away mid-walk. No partial
    ///   breakdown is returned; a half-measured total that reads as complete is worse
    ///   than no number.
    public func breakdown() async throws -> StorageUsageBreakdown {
        lastRunTouchedMainThread = Thread.isMainThread
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)

        let cacheFiles = await cache.allocatedFiles()
        var cacheComponentsByFolder: [String: [MediaComponentBytes]] = [:]
        for file in cacheFiles {
            cacheComponentsByFolder[file.albumFolder, default: []]
                .append(MediaComponentBytes(recordName: file.recordName, bytes: file.allocatedBytes))
        }

        var localMedia = MediaTypeBytes.zero
        var cloudKitMedia: MediaTypeBytes? = .zero
        var iCloudDriveMedia: MediaTypeBytes? = .zero
        var legacyICloudDriveAlbums = 0
        var albumBreakdowns: [AlbumStorageBreakdown] = []
        let driveReachable = driveSizing.isReachable

        for album in albums {
            try Task.checkCancellation()
            let indexBytes = try allocatedIndexBytes(for: album)

            switch album.storageOption {
            case .local:
                let media = MediaTypeBytes.tabulate(try mediaComponents(under: album.storageURL))
                localMedia = localMedia + media
                albumBreakdowns.append(AlbumStorageBreakdown(albumID: album.id,
                                                             storageOption: .local,
                                                             mediaBytes: media,
                                                             indexBytes: indexBytes))
            case .cloudKit:
                let sidecar = makeSidecar(album)
                var media: MediaTypeBytes?
                if await sidecar.existsOnDisk() {
                    let sizes = await sidecar.sizesByRecordName()
                    media = MediaTypeBytes.tabulate(sizes.map { MediaComponentBytes(recordName: $0.key, bytes: $0.value) })
                } else if await indexComponentCount(album) == 0 {
                    media = .zero
                }
                cloudKitMedia = media.flatMap { m in cloudKitMedia.map { $0 + m } }
                let cached = MediaTypeBytes.tabulate(cacheComponentsByFolder[album.storageURL.lastPathComponent] ?? [])
                albumBreakdowns.append(AlbumStorageBreakdown(albumID: album.id,
                                                             storageOption: .cloudKit,
                                                             mediaBytes: media,
                                                             cachedBytes: cached,
                                                             indexBytes: indexBytes))
            case .icloud:
                legacyICloudDriveAlbums += 1
                var media: MediaTypeBytes?
                if driveReachable, let sizes = await driveSizing.logicalSizes(inAlbumDirectory: album.storageURL) {
                    let components = sizes
                        .map { MediaComponentBytes(filename: $0.key, bytes: $0.value) }
                        .filter { $0.type == .photo || $0.type == .video }
                    media = MediaTypeBytes.tabulate(components)
                }
                iCloudDriveMedia = media.flatMap { m in iCloudDriveMedia.map { $0 + m } }
                albumBreakdowns.append(AlbumStorageBreakdown(albumID: album.id,
                                                             storageOption: .icloud,
                                                             mediaBytes: media,
                                                             indexBytes: indexBytes))
            }
        }

        try Task.checkCancellation()
        let cachedCloud = MediaTypeBytes.tabulate(cacheComponentsByFolder.values.flatMap { $0 })

        try Task.checkCancellation()
        let thumbnailBytes = try allocatedBytes(under: thumbnailDirectory)

        try Task.checkCancellation()
        let indexBytes = try allocatedBytes(under: indexDirectory)

        let breakdown = StorageUsageBreakdown(
            localMedia: localMedia,
            cachedCloud: cachedCloud,
            thumbnailBytes: thumbnailBytes,
            indexBytes: indexBytes,
            cloudKitMedia: cloudKitMedia,
            iCloudDriveMedia: iCloudDriveMedia,
            albums: albumBreakdowns,
            legacyICloudDriveAlbumCount: legacyICloudDriveAlbums
        )
        // Byte counts only — never an album name or id, which would put cleartext in the logs.
        printDebug("breakdown ok albums=\(albums.count) device=\(breakdown.totalDeviceBytes) reclaimable=\(breakdown.reclaimableBytes) ck=\(cloudKitMedia.map { String($0.totalBytes) } ?? "unavailable") drive=\(iCloudDriveMedia.map { String($0.totalBytes) } ?? "unavailable") legacyAlbums=\(legacyICloudDriveAlbums)")
        return breakdown
    }

    private static let sizeKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]

    /// Bytes a directory tree occupies as the filesystem allocates them.
    ///
    /// Allocated rather than logical size, because that is what the device's free
    /// space actually reflects, and the two differ meaningfully across the many small
    /// encrypted files an album holds. A directory that does not exist contributes
    /// zero rather than throwing: `CloudKitStorageModel.baseURL` is a pure getter and
    /// may name a directory that was never created.
    private func allocatedBytes(under directory: URL) throws -> Int64 {
        var total: Int64 = 0
        try forEachRegularFile(under: directory) { _, bytes in total += bytes }
        return total
    }

    /// Every regular file under a local album directory, classified by name.
    private func mediaComponents(under directory: URL) throws -> [MediaComponentBytes] {
        var components: [MediaComponentBytes] = []
        try forEachRegularFile(under: directory) { url, bytes in
            components.append(MediaComponentBytes(filename: url.lastPathComponent, bytes: bytes))
        }
        return components
    }

    private func forEachRegularFile(under directory: URL, _ body: (URL, Int64) -> Void) throws {
        guard FileManager.default.fileExists(atPath: directory.path),
              let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: Self.sizeKeys) else {
            return
        }
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen % 128 == 0 { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: Set(Self.sizeKeys)),
                  values.isRegularFile == true else { continue }
            body(url, Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0))
        }
    }

    /// The album's index, size sidecar and cover sidecar, which share one hashed
    /// stem in the index directory (see `MediaIndexStore.indexURL(for:)`,
    /// `AlbumSizeSidecar.sidecarURL(for:)`, `AlbumCoverSidecar.sidecarURL(for:)`).
    private func allocatedIndexBytes(for album: Album) throws -> Int64 {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let stem = digest.map { String(format: "%02x", $0) }.joined()
        var total: Int64 = 0
        for ext in ["encindex", "encsizes", "enccover"] {
            let url = indexDirectory.appendingPathComponent("\(stem).\(ext)")
            guard let values = try? url.resourceValues(forKeys: Set(Self.sizeKeys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Test hooks

    /// Test-only: whether the last walk ran on the main thread. Reachable via `@testable`.
    func _testRanOnMainThread() -> Bool { lastRunTouchedMainThread }
}
