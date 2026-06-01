//
//  MediaIndexStore.swift
//  EncameraCore
//
//  Persists and loads a per-album media index. The index is a derived cache:
//  encrypted with the album key, stored in a local (never-synced) Application
//  Support directory, and always rebuildable from the album's encrypted files.
//

import Foundation
import CryptoKit
import Sodium

/// An in-memory snapshot of a per-album media index.
public struct MediaIndex: Sendable {
    public var entries: [MediaIndexEntry]

    public init(entries: [MediaIndexEntry]) {
        self.entries = entries
    }
}

/// Reads, writes, and (in later stages) rebuilds the per-album media index.
public actor MediaIndexStore {

    private let keyBytes: [UInt8]
    private let indexURL: URL

    public init(album: Album) {
        self.keyBytes = album.key.keyBytes
        self.indexURL = Self.indexURL(for: album)
    }

    /// Direct initializer used by tests to exercise the store without a full `Album`.
    init(keyBytes: [UInt8], indexURL: URL) {
        self.keyBytes = keyBytes
        self.indexURL = indexURL
    }

    // MARK: - Load / Save

    /// Loads and decrypts the index, or returns `nil` if it is absent,
    /// unreadable, or corrupt — the caller should rebuild in that case.
    public func load() -> MediaIndex? {
        guard let fileData = try? Data(contentsOf: indexURL) else {
            return nil
        }
        guard
            let plaintext = try? Self.decrypt(fileData, keyBytes: keyBytes),
            let entries = try? MediaIndexCodec.decode(plaintext)
        else {
            return nil
        }
        return MediaIndex(entries: entries)
    }

    /// Encrypts and atomically writes the index to disk.
    public func save(_ index: MediaIndex) throws {
        let plaintext = MediaIndexCodec.encode(index.entries)
        let encrypted = try Self.encrypt(plaintext, keyBytes: keyBytes)
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encrypted.write(to: indexURL, options: .atomic)
        Self.excludeFromBackup(indexURL)
    }

    // MARK: - File location

    /// `~/Library/Application Support/MediaIndex/` — a local, never-synced
    /// directory holding the derived index cache.
    static func indexDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MediaIndex", isDirectory: true)
    }

    /// The index file for an album, named by a hash of the album id so the
    /// cleartext album name never appears on disk.
    static func indexURL(for album: Album) -> URL {
        let digest = SHA256.hash(data: Data(album.id.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return indexDirectoryURL().appendingPathComponent("\(hash).encindex")
    }

    /// Whether an index file already exists on disk for the album.
    public static func hasIndex(for album: Album) -> Bool {
        FileManager.default.fileExists(atPath: indexURL(for: album).path)
    }

    /// Deletes the entire on-disk media index cache for all albums. The index
    /// is a derived cache and will be rebuilt by `MediaIndexMigration` on the
    /// next app launch. Debug-only; used to test the index build flow.
    public static func clearAllIndexes() throws {
        let dir = indexDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Returns the modification date of the on-disk index file, or `nil` if
    /// the file does not exist.
    public nonisolated func fileModificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Encryption

    /// Encrypts an index blob with the album key. The layout — stream header
    /// followed by ciphertext — matches `EncryptedMetadataHandler`.
    static func encrypt(_ data: Data, keyBytes: [UInt8]) throws -> Data {
        let sodium = Sodium()
        guard let stream = sodium.secretStream.xchacha20poly1305.initPush(secretKey: keyBytes) else {
            throw MediaIndexError.encryptionFailed
        }
        let header = stream.header()
        guard let ciphertext = stream.push(message: Array(data), tag: .FINAL) else {
            throw MediaIndexError.encryptionFailed
        }
        var result = Data()
        result.reserveCapacity(header.count + ciphertext.count)
        result.append(contentsOf: header)
        result.append(contentsOf: ciphertext)
        return result
    }

    static func decrypt(_ data: Data, keyBytes: [UInt8]) throws -> Data {
        let headerSize = EncryptedFileFormat.streamHeaderSize
        guard data.count > headerSize else {
            throw MediaIndexError.decryptionFailed
        }
        let header = Array(data.prefix(headerSize))
        let ciphertext = Array(data.dropFirst(headerSize))
        let sodium = Sodium()
        guard let stream = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: header) else {
            throw MediaIndexError.decryptionFailed
        }
        guard let (plaintext, _) = stream.pull(cipherText: ciphertext) else {
            throw MediaIndexError.decryptionFailed
        }
        return Data(plaintext)
    }
}
