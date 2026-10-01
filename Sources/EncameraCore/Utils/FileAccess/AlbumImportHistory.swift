import Foundation
import CryptoKit

/// One finished import into an album: what the user selected, what made it in,
/// and — for photo-library imports — the originals they may still delete.
public struct ImportHistoryRecord: Codable, Identifiable, Equatable, Sendable {

    public enum State: String, Codable, Sendable {
        case completed
        case cancelled
    }

    /// The user batch id: one per selection, however the import was split.
    public let id: String
    public let createdAt: Date
    public let source: ImportSource
    public let importedCount: Int
    public let requestedCount: Int
    /// Photo-library identifiers of the items that imported successfully. Never
    /// includes an item that failed or was never reached, so deleting them can
    /// only remove originals the album actually holds.
    public let assetIdentifiers: [String]
    public let state: State
    public var deletedFromLibraryAt: Date?

    public init(id: String,
                createdAt: Date,
                source: ImportSource,
                importedCount: Int,
                requestedCount: Int,
                assetIdentifiers: [String],
                state: State,
                deletedFromLibraryAt: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.importedCount = importedCount
        self.requestedCount = requestedCount
        self.assetIdentifiers = assetIdentifiers
        self.state = state
        self.deletedFromLibraryAt = deletedFromLibraryAt
    }

    /// Whether the history can still offer to delete this batch's originals.
    public var canDeleteFromLibrary: Bool {
        !assetIdentifiers.isEmpty && deletedFromLibraryAt == nil
    }
}

/// Per-album import history, kept beside the album's media index.
///
/// A derived, device-local cache like the size and cover sidecars: it lives in the
/// never-synced `MediaIndex` directory under a hash of the album id, is excluded
/// from backup, and losing it only loses the history. Unlike those sidecars it is
/// encrypted with the album key, because asset identifiers say which camera-roll
/// photos went into the vault. Photo-library identifiers are only meaningful on
/// the device that recorded them, which is why the file must never sync.
///
/// Not thread-safe on its own; every caller runs on the main actor.
public struct AlbumImportHistory {

    /// The newest batches kept per album; appending past this drops the oldest.
    public static let maximumRecords = 200

    public static let didChangeNotification = Notification.Name("AlbumImportHistoryDidChange")
    /// `userInfo` key carrying the changed album's id.
    public static let albumIdKey = "albumId"

    private struct Payload: Codable {
        var version: Int = 1
        var records: [ImportHistoryRecord]
    }

    private let albumId: String
    private let keyBytes: [UInt8]
    let fileURL: URL

    public init(album: Album) {
        self.init(albumId: album.id, keyBytes: album.key.keyBytes, fileURL: Self.fileURL(forAlbumId: album.id))
    }

    init(albumId: String, keyBytes: [UInt8], fileURL: URL) {
        self.albumId = albumId
        self.keyBytes = keyBytes
        self.fileURL = fileURL
    }

    public static func fileURL(forAlbumId albumId: String) -> URL {
        let digest = SHA256.hash(data: Data(albumId.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return MediaIndexStore.indexDirectoryURL().appendingPathComponent("\(hash).encimports")
    }

    // MARK: - Reading

    /// Every recorded batch, newest first. An absent or unreadable file reads as
    /// an empty history.
    public func records() -> [ImportHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let plaintext = try? MediaIndexStore.decrypt(data, keyBytes: keyBytes),
              let payload = try? JSONDecoder().decode(Payload.self, from: plaintext) else {
            return []
        }
        return payload.records.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Writing

    public func append(_ record: ImportHistoryRecord) throws {
        var records = records().filter { $0.id != record.id }
        records.append(record)
        records.sort { $0.createdAt > $1.createdAt }
        try write(Array(records.prefix(Self.maximumRecords)))
    }

    /// Marks the batches whose ids are given as deleted from the photo library.
    public func markDeletedFromLibrary(ids: Set<String>, at date: Date = Date()) throws {
        var records = records()
        var changed = false
        for index in records.indices where ids.contains(records[index].id) && records[index].deletedFromLibraryAt == nil {
            records[index].deletedFromLibraryAt = date
            changed = true
        }
        if changed {
            try write(records)
        }
    }

    public func remove(id: String) throws {
        try write(records().filter { $0.id != id })
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        postChange(albumId: albumId)
    }

    // MARK: - Album lifecycle

    /// Removes the history of the album with this id, if any.
    public static func deleteFile(forAlbumId albumId: String) throws {
        let url = fileURL(forAlbumId: albumId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Carries the history over when an album's id changes without its contents
    /// changing (a rename). The key is unchanged, so the file moves as-is.
    public static func moveFile(fromAlbumId oldId: String, toAlbumId newId: String) throws {
        let source = fileURL(forAlbumId: oldId)
        guard oldId != newId, FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = fileURL(forAlbumId: newId)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    // MARK: - Private

    private func write(_ records: [ImportHistoryRecord]) throws {
        let plaintext = try JSONEncoder().encode(Payload(records: records))
        let ciphertext = try MediaIndexStore.encrypt(plaintext, keyBytes: keyBytes)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try ciphertext.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        postChange(albumId: albumId)
    }

    private func postChange(albumId: String) {
        NotificationCenter.default.post(name: Self.didChangeNotification,
                                        object: nil,
                                        userInfo: [Self.albumIdKey: albumId])
    }
}
