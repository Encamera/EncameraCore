//
//  MigrationReencryption.swift
//  EncameraCore
//
//  Support for the ENC2 -> ENC3 re-encryption a move to CloudKit does for large
//  legacy videos: the scratch directories that hold its decrypted plaintext, and
//  the check that the ENC3 it wrote decrypts back to that plaintext. The
//  re-encrypted file is the only copy that reaches CloudKit, and the ENC2
//  original is deleted once the record is verified, so it has to be proven
//  playable before it is uploaded.
//

import Foundation

// MARK: - Scratch directories

/// The `tmp/migration-enc3-<uuid>` directories a re-encryption works in. Each
/// holds a decrypted copy of a video while it is being re-encrypted, so one left
/// behind by a crash or jetsam is plaintext on disk until something removes it.
/// Directories in use by this process are tracked, so a sweep that runs while a
/// move is under way (the background sweep) leaves them alone.
public enum MigrationReencryptScratch {
    public static let directoryPrefix = "migration-enc3-"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: Set<String> = []

    /// Creates a fresh scratch directory under `root` and marks it in use.
    static func makeDirectory(in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent("\(directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.withLock { _ = active.insert(directory.standardizedFileURL.path) }
        return directory
    }

    /// Removes a scratch directory and everything in it, and stops tracking it.
    static func release(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        lock.withLock { _ = active.remove(directory.standardizedFileURL.path) }
    }

    /// Removes every scratch directory under `root` that this process is not
    /// using. Returns how many it removed.
    @discardableResult
    public static func sweepLeftovers(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        let inUse = lock.withLock { active }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(directoryPrefix) {
            guard !inUse.contains(entry.standardizedFileURL.path) else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - Verification

/// Why a re-encrypted ENC3 file was rejected.
public enum ReencryptVerificationError: Error, Equatable {
    /// The header on disk is not the one the writer reported writing.
    case headerMismatch
    /// The header's plaintext length is not the plaintext's.
    case plaintextLengthMismatch(expected: Int, header: Int)
    /// The header's chunk count does not follow from its length and chunk size.
    case chunkCountMismatch(expected: Int, header: Int)
    /// The file is not exactly as long as its header says it should be: a chunk
    /// is short (a short source read, a truncated write) or bytes follow the last.
    case fileSizeMismatch(expected: Int, actual: Int)
    /// The embedded metadata does not open, or does not match what was written.
    case metadataMismatch
    /// A chunk does not decrypt.
    case chunkUnreadable(index: Int, reason: String)
    /// A chunk decrypts to bytes other than the plaintext's at that range.
    case chunkMismatch(index: Int)
}

enum ReencryptVerifier {
    /// Proves `enc3` is a playable copy of `plaintext`: decrypts every chunk
    /// through `SeekableEncryptedReader`, the reader playback uses, and compares
    /// each against the same range of the plaintext file. Also checks the header
    /// against `writtenHeader`, the geometry against the plaintext's length and
    /// the file's size, and the metadata against `metadata`. Throws
    /// `ReencryptVerificationError` on the first difference.
    static func verify(enc3: URL,
                       plaintext: URL,
                       keyBytes: [UInt8],
                       writtenHeader: SeekableEncryptedHeader,
                       metadata: Data?) async throws {
        let reader = try SeekableEncryptedReader.forFile(enc3, keyBytes: keyBytes)
        let header = reader.header
        guard header == writtenHeader else { throw ReencryptVerificationError.headerMismatch }

        let plaintextLength = try fileSize(plaintext)
        guard header.plaintextLength == plaintextLength else {
            throw ReencryptVerificationError.plaintextLengthMismatch(expected: plaintextLength,
                                                                     header: header.plaintextLength)
        }
        let geometry = header.geometry
        guard header.chunkCount == geometry.chunkCount else {
            throw ReencryptVerificationError.chunkCountMismatch(expected: geometry.chunkCount,
                                                                header: header.chunkCount)
        }
        let enc3Size = try fileSize(enc3)
        guard enc3Size == geometry.totalCiphertextLength else {
            throw ReencryptVerificationError.fileSizeMismatch(expected: geometry.totalCiphertextLength,
                                                              actual: enc3Size)
        }

        let openedMetadata: Data?
        do {
            openedMetadata = try reader.metadata()
        } catch {
            throw ReencryptVerificationError.metadataMismatch
        }
        guard openedMetadata == (metadata?.isEmpty == true ? nil : metadata) else {
            throw ReencryptVerificationError.metadataMismatch
        }

        // Every chunk, not a sample: the comparison reads the file once more and
        // costs one AEAD open per chunk, small next to the decrypt and encrypt
        // that produced it, and a sample would pass a file with one bad chunk.
        let source = try FileHandle(forReadingFrom: plaintext)
        defer { try? source.close() }
        for index in 0..<geometry.chunkCount {
            let decrypted: Data
            do {
                decrypted = try await reader.plaintextChunk(at: index)
            } catch {
                throw ReencryptVerificationError.chunkUnreadable(index: index, reason: "\(error)")
            }
            let expected = try source.read(upToCount: geometry.plaintextSize(ofChunk: index)) ?? Data()
            guard decrypted == expected else { throw ReencryptVerificationError.chunkMismatch(index: index) }
        }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
