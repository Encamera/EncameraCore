import Foundation

/// One-time migration: moves legacy album directories from each storage root
/// into a dedicated `./albums` subdirectory, so the root can host other siblings
/// (thumbnails, RevenueCat, etc.) without colliding with album enumeration.
///
/// "Album directory" is `AlbumDirectoryNaming`'s definition, which covers both
/// the encrypted `Album_*` names and the plaintext names that predate name
/// encryption.
public final class AlbumsDirectoryMigrationUtil: DebugPrintable {

    /// V2 widened the candidate set from `Album_*` to every album directory,
    /// including the plaintext names that predate name encryption. Devices that
    /// already ran V1 left those behind, so the key is bumped rather than reused —
    /// a device stuck on the V1 flag would never revisit them.
    static let flagKey = "completedAlbumsDirectoryMigrationV2"

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
        let model = storageType.modelForType
        recoverMisplacedRevenueCat(in: model.albumsURL, backTo: model.rootURL)
        guard !hasMigrated(storageType) else { return }
        if performMigration(at: model.rootURL, into: model.albumsURL) {
            markMigrated(storageType)
        }
    }

    /// Moves every album directory at `rootURL` into `albumsURL`.
    /// Returns `true` iff every candidate either moved successfully or was safely
    /// skipped (destination exists). With nothing to move the root is left
    /// untouched: creating `albums/` here would plant a directory in a fresh
    /// install's iCloud Drive container, which the existing-data probe then
    /// reports as legacy data. Exposed as `internal` for testing.
    @discardableResult
    func performMigration(at rootURL: URL, into albumsURL: URL) -> Bool {
        recoverMisplacedRevenueCat(in: albumsURL, backTo: rootURL)

        let candidates: [URL]
        do {
            candidates = try legacyAlbumCandidates(at: rootURL, albumsURL: albumsURL)
        } catch {
            printDebug("Could not enumerate legacy albums at \(rootURL.path): \(error)")
            return false
        }
        guard !candidates.isEmpty else { return true }

        do {
            try fileManager.createDirectory(at: albumsURL, withIntermediateDirectories: true)
        } catch {
            printDebug("Could not create albumsURL at \(albumsURL.path): \(error)")
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
            guard AlbumDirectoryNaming.isAlbumDirectoryName(url.lastPathComponent) else { return false }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return false }
            return url.deletingLastPathComponent().standardizedFileURL != standardizedAlbumsURL
        }
    }

    /// Moves RevenueCat's directories out of `albumsURL` and back to `rootURL`.
    /// An earlier V2 migration treated them as albums and moved them; the SDK
    /// keeps writing to the root and expects its caches there. Runs on every
    /// launch, not only before the flag is set, because those devices already
    /// carry the flag. A directory already present at the root is left alone.
    private func recoverMisplacedRevenueCat(in albumsURL: URL, backTo rootURL: URL) {
        guard fileManager.fileExists(atPath: albumsURL.path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: albumsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        for url in contents {
            guard url.lastPathComponent.lowercased().contains("revenuecat") else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let destURL = rootURL.appendingPathComponent(url.lastPathComponent)
            guard !fileManager.fileExists(atPath: destURL.path) else {
                printDebug("Recovery destination exists, skipping: \(url.lastPathComponent)")
                continue
            }
            do {
                try fileManager.moveItem(at: url, to: destURL)
                printDebug("Recovered misplaced directory: \(url.lastPathComponent)")
            } catch {
                printDebug("Failed to recover \(url.lastPathComponent): \(error)")
            }
        }
    }

    private func moveAlbum(from sourceURL: URL, to destURL: URL) throws {
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

    /// Internal for testing, alongside `performMigration`: the flag key's
    /// version is what makes an already-migrated device revisit its storage roots.
    func hasMigrated(_ type: StorageType) -> Bool {
        migratedSet().contains(type.rawValue)
    }

    func markMigrated(_ type: StorageType) {
        var set = migratedSet()
        set.insert(type.rawValue)
        userDefaults.set(Array(set), forKey: Self.flagKey)
    }
}
