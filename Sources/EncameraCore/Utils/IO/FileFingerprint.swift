//
//  FileFingerprint.swift
//  EncameraCore
//

import Foundation
import CryptoKit

/// A one-line description of a file for diagnostic logs: whether it exists, its
/// size, modification time, first four bytes and a short SHA-256 of its
/// contents. It only ever reads ciphertext and file-system metadata, so it is
/// safe to log for encrypted media and previews.
///
/// The same encrypted thumbnail is logged when a device writes it, when it is
/// uploaded to CloudKit, and when another device downloads it. Matching sizes
/// and hashes across those lines show where the bytes changed.
enum FileFingerprint {
    /// Larger files are not hashed, so describing a full photo or video stays
    /// cheap. Previews are far below this.
    static let maxHashedBytes: Int64 = 4 * 1024 * 1024

    static func describe(_ url: URL?) -> String {
        guard let url else { return "file=nil" }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "file=\(url.lastPathComponent) exists=false"
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        var parts = ["file=\(url.lastPathComponent)", "exists=true", "sizeBytes=\(size)"]
        if let modified = attributes[.modificationDate] as? Date {
            parts.append("modified=\(timestampFormatter.string(from: modified))")
        }
        if size > 0, size <= maxHashedBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            parts.append("magic=\(hex(data.prefix(4)))")
            parts.append("sha256=\(hex(SHA256.hash(data: data).prefix(8)))")
        } else if size > 0, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 4) {
                parts.append("magic=\(hex(head))")
            }
            parts.append("sha256=skipped(tooLarge)")
        }
        return parts.joined(separator: " ")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
