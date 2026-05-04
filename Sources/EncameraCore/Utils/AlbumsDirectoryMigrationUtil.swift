import Foundation

/// One-time migration: moves legacy `Album_*` directories from each storage
/// root into a dedicated `./albums` subdirectory, so the root can host other
/// siblings (thumbnails, RevenueCat, etc.) without colliding with album
/// enumeration.
public final class AlbumsDirectoryMigrationUtil: DebugPrintable {

    static let flagKey = "completedAlbumsDirectoryMigrationV1"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    public init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    /// Runs migration for every currently-available storage type. Synchronous.
    /// Safe to call repeatedly — completed types are skipped via a persisted flag,
    /// and individual moves are idempotent by destination existence.
    public func migrateIfNeeded() {
        migrate(storageType: .local)
        if case .available = DataStorageAvailabilityUtil.isStorageTypeAvailable(type: .icloud) {
            migrate(storageType: .icloud)
        }
    }

    private func migrate(storageType: StorageType) {
        guard !hasMigrated(storageType) else { return }
        let model = storageType.modelForType
        if performMigration(at: model.rootURL, into: model.albumsURL) {
            markMigrated(storageType)
        }
    }

    /// Moves every legacy `Album_*` directory at `rootURL` into `albumsURL`.
    /// Returns `true` iff the destination was prepared and every candidate
    /// either moved successfully or was safely skipped (destination exists).
    /// Exposed as `internal` for testing.
    @discardableResult
    func performMigration(at rootURL: URL, into albumsURL: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        } catch {
            printDebug("Could not create albumsURL at \(albumsURL.path): \(error)")
            return false
        }

        let candidates: [URL]
        do {
            candidates = try legacyAlbumCandidates(at: rootURL, albumsURL: albumsURL)
        } catch {
            printDebug("Could not enumerate legacy albums at \(rootURL.path): \(error)")
            return false
        }

        var allSucceeded = true
        for sourceURL in candidates {
            let destURL = albumsURL.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try moveAlbum(from: sourceURL, to: destURL)
            } catch {
                printDebug("Failed to move \(sourceURL.lastPathComponent): \(error)")
                allSucceeded = false
            }
        }

        return allSucceeded
    }

    private func legacyAlbumCandidates(at rootURL: URL, albumsURL: URL) throws -> [URL] {
        _ = rootURL.startAccessingSecurityScopedResource()
        defer { rootURL.stopAccessingSecurityScopedResource() }

        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        let standardizedAlbumsURL = albumsURL.standardizedFileURL
        return contents.filter { url in
            guard url.lastPathComponent.hasPrefix("Album_") else { return false }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return false }
            // Defensive: if it's already under albumsURL, leave it alone.
            return url.deletingLastPathComponent().standardizedFileURL != standardizedAlbumsURL
        }
    }

    private func moveAlbum(from sourceURL: URL, to destURL: URL) throws {
        // Never clobber an existing destination — treat as already migrated.
        if fileManager.fileExists(atPath: destURL.path) {
            printDebug("Destination exists, skipping: \(destURL.lastPathComponent)")
            return
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var innerError: Error?

        coordinator.coordinate(
            writingItemAt: sourceURL, options: .forMoving,
            writingItemAt: destURL, options: .forReplacing,
            error: &coordinatorError
        ) { newSource, newDest in
            do {
                try fileManager.moveItem(at: newSource, to: newDest)
            } catch {
                innerError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let innerError {
            throw innerError
        }
    }

    // MARK: - Flag persistence

    private func migratedSet() -> Set<String> {
        let raw = userDefaults.array(forKey: Self.flagKey) as? [String] ?? []
        return Set(raw)
    }

    private func hasMigrated(_ type: StorageType) -> Bool {
        migratedSet().contains(type.rawValue)
    }

    private func markMigrated(_ type: StorageType) {
        var set = migratedSet()
        set.insert(type.rawValue)
        userDefaults.set(Array(set), forKey: Self.flagKey)
    }
}
