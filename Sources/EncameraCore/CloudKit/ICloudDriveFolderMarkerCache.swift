//
//  ICloudDriveFolderMarkerCache.swift
//  EncameraCore
//
//  The marker of each iCloud Drive album folder, read off the main thread so
//  album listing never waits on iCloud Drive.
//

import Foundation

/// What an iCloud Drive album folder's marker says, read in the background and
/// kept for the life of one `AlbumManager`.
///
/// Reading a marker asks iCloud Drive for the file's download state, looks up
/// its `NSFileVersion` conflicts and reads it through an `NSFileCoordinator`.
/// Any of those can block for seconds behind a slow File Provider, so a listing
/// only reads what is cached here. A reading is current while the folder's
/// modification date is unchanged; a marker rewritten, evicted or downloaded
/// changes the folder. A current reading older than `maxReadingAge` is still
/// used and is read again in the background, which also picks up a conflict
/// version arriving without a change to the folder.
final class ICloudDriveFolderMarkerCache: @unchecked Sendable {

    /// One read of a folder's marker.
    struct Reading: Equatable, Sendable {
        let marker: ICloudDriveAlbumMarkerFile.ReadResult
        /// The folder's path relative to the iCloud Drive root
        /// (`CloudKitAlbumMarker.iCloudDriveFolderPath`).
        let folderPath: String?
    }

    /// A cached reading and whether it still describes the folder.
    struct Lookup {
        let reading: Reading
        /// False when the folder changed after the reading was taken.
        let isCurrent: Bool
        /// True when the reading is current but due to be read again.
        let isDueForRefresh: Bool
    }

    private struct Entry {
        let reading: Reading
        let folderModified: Date?
        let readAt: Date
    }

    static let maxReadingAge: TimeInterval = 60

    /// Reads one folder's marker. Runs off the main thread.
    let readMarker: @Sendable (URL) -> Reading
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Reading, Never>] = [:]
    /// Whether a background read changed a reading since the last batch of reads
    /// finished.
    private var readingChangedInBatch = false

    init(readMarker: @escaping @Sendable (URL) -> Reading = ICloudDriveFolderMarkerCache.readMarkerFromDisk(of:),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.readMarker = readMarker
        self.now = now
    }

    /// Reads `folder`'s marker and its root-relative path from iCloud Drive.
    static func readMarkerFromDisk(of folder: URL) -> Reading {
        Reading(marker: ICloudDriveAlbumMarkerFile.read(fromAlbumDirectory: folder),
                folderPath: CloudKitAlbumMarker.iCloudDriveFolderPath(for: folder))
    }

    /// The reading cached for `folder`, or nil when it has never been read.
    func lookup(_ folder: URL) -> Lookup? {
        let path = Self.key(folder)
        let modified = Self.modificationDate(of: folder)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path] else { return nil }
        let isCurrent = entry.folderModified == modified
        return Lookup(reading: entry.reading,
                      isCurrent: isCurrent,
                      isDueForRefresh: isCurrent && now().timeIntervalSince(entry.readAt) > Self.maxReadingAge)
    }

    /// Reads `folder`'s marker on the calling thread and caches it.
    func readNow(_ folder: URL) -> Reading {
        let modified = Self.modificationDate(of: folder)
        let reading = readMarker(folder)
        store(reading, path: Self.key(folder), folderModified: modified)
        return reading
    }

    /// Reads `folder`'s marker off the caller's thread, joining a read already
    /// running for it, and caches the result. `onFinished` runs once, only for
    /// the call that started the read. Its argument is true for exactly one read
    /// of each batch, the last to finish while no other read is running, and only
    /// when some read in the batch found a reading different from the one cached
    /// before (or none was).
    @discardableResult
    func readInBackground(_ folder: URL,
                          onFinished: (@Sendable (_ batchChangedReadings: Bool) -> Void)? = nil) -> Task<Reading, Never> {
        let path = Self.key(folder)
        lock.lock()
        if let running = inFlight[path] {
            lock.unlock()
            return running
        }
        let previous = entries[path]?.reading
        let readMarker = self.readMarker
        let task = Task.detached(priority: .utility) { [weak self] () -> Reading in
            let modified = Self.modificationDate(of: folder)
            let reading = readMarker(folder)
            let batchChangedReadings = self?.finish(reading, changed: reading != previous,
                                                    path: path, folderModified: modified) ?? false
            onFinished?(batchChangedReadings)
            return reading
        }
        inFlight[path] = task
        lock.unlock()
        return task
    }

    /// Waits for every read running now.
    func waitForReads() async {
        let running: [Task<Reading, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(inFlight.values)
        }()
        for task in running {
            _ = await task.value
        }
    }

    private func store(_ reading: Reading, path: String, folderModified: Date?) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = Entry(reading: reading, folderModified: folderModified, readAt: now())
    }

    /// Caches a finished read and returns whether it closes a batch in which a
    /// reading changed.
    private func finish(_ reading: Reading, changed: Bool, path: String, folderModified: Date?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = Entry(reading: reading, folderModified: folderModified, readAt: now())
        inFlight[path] = nil
        if changed { readingChangedInBatch = true }
        guard inFlight.isEmpty, readingChangedInBatch else { return false }
        readingChangedInBatch = false
        return true
    }

    private static func key(_ folder: URL) -> String {
        folder.standardizedFileURL.path
    }

    private static func modificationDate(of folder: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
    }
}
