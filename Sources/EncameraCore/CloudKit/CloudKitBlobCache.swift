//
//  CloudKitBlobCache.swift
//  EncameraCore
//
//  The app-controlled, evictable local cache for CloudKit blobs — the lever
//  Option A unlocks ("iCloud is the backend, local is an evictable cache",
//  decision doc §3). Holds the *encrypted* ENC2 file only; it is re-fetchable
//  and never the source of truth, so it lives under Caches and is excluded from
//  backup. `.local` albums never touch this cache.
//

import Foundation
import CryptoKit

public actor CloudKitBlobCache {

    /// Per-album residency policy for fetched blobs.
    public enum Mode: Sendable {
        case keepLocal     // authoring device / opted-in: keep the file resident
        case fetchOnTap    // non-authoring device default: evictable on pressure
    }

    private struct Entry: Codable {
        let changeTag: String?
        /// Path relative to `baseDir`, so the cache survives a Caches relocation.
        let relativePath: String
        let size: Int64
        var lastAccess: Date
    }

    private let baseDir: URL
    private let maxBytes: Int64
    private var index: [String: Entry] = [:]

    private var indexFileURL: URL { baseDir.appendingPathComponent(".cacheindex.json") }
    private func url(for entry: Entry) -> URL { baseDir.appendingPathComponent(entry.relativePath) }

    public static var defaultBaseDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("CloudKitBlobs", isDirectory: true)
    }

    /// The process-wide cache. All coordinators share ONE instance so the on-disk
    /// `.cacheindex.json` has a single in-memory owner — separate instances writing
    /// it from divergent snapshots would clobber each other.
    public static let shared = CloudKitBlobCache()

    public init(baseDir: URL = CloudKitBlobCache.defaultBaseDir,
                maxBytes: Int64 = 500 * 1024 * 1024) {
        self.baseDir = baseDir
        self.maxBytes = maxBytes
        loadIndex()
    }

    /// Filesystem-safe per-album folder name derived from the (base64, possibly
    /// slash-containing) `albumID`. Used by BOTH the cache and `CloudKitStorageModel`
    /// so they agree on one tree (no duplicate copies, no path divergence).
    public static func albumFolderName(_ albumID: String) -> String {
        let digest = SHA256.hash(data: Data(albumID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lookup

    /// The cached file for `recordName`, but only if its `changeTag` matches the
    /// caller's expectation. A server-side change (new tag) invalidates the stale
    /// copy — CloudKit gives no durable "won't re-download" guarantee, so we own
    /// dedup (decision doc §5).
    ///
    /// A `nil` expectation means the caller has observed no tag yet (e.g. a fresh
    /// launch before delta sync repopulates its in-memory tag map) — trust the
    /// persisted entry rather than re-downloading everything; the next sync
    /// supplies a real tag and evicts genuinely stale copies via the mismatch.
    public func cachedURL(recordName: String, changeTag: String?) -> URL? {
        guard var entry = index[recordName] else { return nil }
        if let changeTag, entry.changeTag != changeTag { return nil }
        let fileURL = url(for: entry)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            index[recordName] = nil
            return nil
        }
        entry.lastAccess = Date()
        index[recordName] = entry
        return fileURL
    }

    // MARK: - Store

    /// Copy `sourceURL` into the cache for `recordName`, replacing any prior copy,
    /// then enforce the size cap by LRU eviction. Returns the cached URL.
    @discardableResult
    public func store(recordName: String,
                      changeTag: String?,
                      albumID: String,
                      from sourceURL: URL) throws -> URL {
        let albumFolder = Self.albumFolderName(albumID)
        let albumDir = baseDir.appendingPathComponent(albumFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)

        if let existing = index[recordName] {
            try? FileManager.default.removeItem(at: url(for: existing))
        }
        var destURL = albumDir.appendingPathComponent(recordName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        excludeFromBackup(&destURL)

        let attributes = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        index[recordName] = Entry(changeTag: changeTag,
                                  relativePath: "\(albumFolder)/\(recordName)",
                                  size: size,
                                  lastAccess: Date())
        enforceCap()
        persist()
        return destURL
    }

    // MARK: - Eviction

    public func evict(recordName: String) {
        guard let entry = index.removeValue(forKey: recordName) else { return }
        try? FileManager.default.removeItem(at: url(for: entry))
        persist()
    }

    public func evictAll(olderThan date: Date) {
        for (recordName, entry) in index where entry.lastAccess < date {
            try? FileManager.default.removeItem(at: url(for: entry))
            index[recordName] = nil
        }
        persist()
    }

    public func totalBytes() -> Int64 {
        index.values.reduce(0) { $0 + $1.size }
    }

    /// Wipes the entire on-disk cache (every album folder and the `.cacheindex.json`
    /// sidecar) and clears the in-memory index. Used by "Erase All Data" so no
    /// cached ciphertext blobs survive a full reset.
    public func clearAll() {
        try? FileManager.default.removeItem(at: baseDir)
        index.removeAll()
    }

    // MARK: - Internals

    private func enforceCap() {
        guard maxBytes > 0 else { return }
        var total = totalBytes()
        guard total > maxBytes else { return }
        // Evict least-recently-used first.
        let ordered = index.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (recordName, entry) in ordered {
            if total <= maxBytes { break }
            try? FileManager.default.removeItem(at: url(for: entry))
            index[recordName] = nil
            total -= entry.size
        }
    }

    private func excludeFromBackup(_ url: inout URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Persistence (survive relaunch)

    /// Rebuild the in-memory index from the on-disk sidecar, dropping entries whose
    /// file no longer exists. Without this, a relaunch re-downloads everything and
    /// orphans on-disk files outside the byte cap.
    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        index = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0.value).path) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? data.write(to: indexFileURL)
    }
}
