//
//  ICloudDriveAlbumMarkerFile.swift
//  EncameraCore
//
//  The file inside an iCloud Drive album folder that names the CloudKit album
//  the folder belongs to. iCloud Drive syncs it to every device, so any device
//  walking its album folders can link a folder to its `EncAlbum` by reading it.
//
//  It holds the random `albumID` and a format version, nothing else: no name, no
//  path, no key material. The `albumID` says nothing about the album, so the file
//  is plain JSON, and every device can read it without a key.
//
//  The file sits among the album's media, so every walk of an album folder skips
//  it through `isMarkerFile(_:)` / `isMarkerFileName(_:)`.
//

import Foundation

public struct ICloudDriveAlbumMarkerFile: Codable, Equatable, Sendable, DebugPrintable {

    /// The marker's file name inside the album folder.
    public static let fileName = ".encamera-cloudkit-album.json"

    /// The newest format this build reads and the one it writes.
    public static let currentFormatVersion = 1

    public let albumID: String
    public let formatVersion: Int

    public init(albumID: String, formatVersion: Int = ICloudDriveAlbumMarkerFile.currentFormatVersion) {
        self.albumID = albumID
        self.formatVersion = formatVersion
    }

    // MARK: - Recognizing the file

    /// The name iCloud gives the marker while it is evicted.
    static var placeholderFileName: String { ".\(fileName).icloud" }

    /// Whether `name` is the marker, materialized or as its iCloud placeholder.
    public static func isMarkerFileName(_ name: String) -> Bool {
        name == fileName || name == placeholderFileName
    }

    /// Whether `url` is the marker, materialized or as its iCloud placeholder.
    public static func isMarkerFile(_ url: URL) -> Bool {
        isMarkerFileName(url.lastPathComponent)
    }

    /// Where the marker lives in `directory`.
    public static func url(inAlbumDirectory directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Encoding

    /// The file's bytes: a JSON object with exactly `albumID` and `formatVersion`.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes the file's bytes. Nil when they are not a marker this build
    /// understands, including one written in a newer format.
    public static func decode(_ data: Data) -> ICloudDriveAlbumMarkerFile? {
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(FormatVersionProbe.self, from: data).formatVersion,
              (1...currentFormatVersion).contains(version),
              let marker = try? decoder.decode(ICloudDriveAlbumMarkerFile.self, from: data),
              !marker.albumID.isEmpty else {
            return nil
        }
        return marker
    }

    /// Reads only the version, so a newer format with a different shape is
    /// recognized as newer rather than as damaged.
    private struct FormatVersionProbe: Decodable {
        let formatVersion: Int
    }

    // MARK: - Reading

    public enum ReadResult: Equatable, Sendable {
        /// No marker in the folder, in any form.
        case absent
        /// Only an iCloud placeholder is on this device; the contents are not
        /// readable until it downloads.
        case evicted
        case present(ICloudDriveAlbumMarkerFile)
        /// The file has unresolved iCloud conflict versions. The current version
        /// comes first, then each conflict version.
        case conflicted([ICloudDriveAlbumMarkerFile])
        /// The file (or one of its conflict versions) is there but does not
        /// decode, or it was written in a newer format.
        case unreadable
    }

    /// The URLs of `NSFileVersion`'s unresolved conflict versions of the file at `url`.
    public static func unresolvedConflictVersionURLs(of url: URL) -> [URL] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map(\.url)
    }

    /// Resolves the conflict on the marker file at `url` in favour of `kept`.
    ///
    /// Inside one coordinated write it writes `kept` as the file's current version
    /// when it is not already, marks every unresolved conflict version resolved and
    /// removes the other versions. The current version is rewritten in place, not
    /// replaced, so the versions stay attached to the file being resolved.
    public static func resolveConflict(at url: URL, keeping kept: ICloudDriveAlbumMarkerFile) throws {
        let data = try kept.encoded()
        var resolveError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url,
                                                         options: [],
                                                         error: &coordinationError) { writeURL in
            do {
                if (try? Data(contentsOf: writeURL)).flatMap(decode) != kept {
                    try data.write(to: writeURL)
                }
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: writeURL) ?? [] {
                    version.isResolved = true
                }
                try NSFileVersion.removeOtherVersionsOfItem(at: writeURL)
            } catch {
                resolveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let resolveError { throw resolveError }
    }

    /// Reads the marker in `directory` through a coordinated read.
    ///
    /// - Parameter conflictVersions: returns the URLs of the unresolved conflict
    ///   versions of the marker at the URL it is given.
    public static func read(fromAlbumDirectory directory: URL,
                            conflictVersions: (URL) -> [URL] = unresolvedConflictVersionURLs(of:)) -> ReadResult {
        let url = url(inAlbumDirectory: directory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            let placeholder = ICloudPlaceholderName.placeholderURL(forMaterialized: url)
            return fileManager.fileExists(atPath: placeholder.path) ? .evicted : .absent
        }
        guard ICloudPlaceholderName.isMaterialized(url) else { return .evicted }

        guard let data = coordinatedRead(url) else { return .unreadable }
        guard let current = decode(data) else { return .unreadable }

        let conflictURLs = conflictVersions(url)
        guard !conflictURLs.isEmpty else { return .present(current) }

        var versions = [current]
        for conflictURL in conflictURLs {
            guard let conflictData = try? Data(contentsOf: conflictURL),
                  let conflict = decode(conflictData) else {
                return .unreadable
            }
            versions.append(conflict)
        }
        return .conflicted(versions)
    }

    private static func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url,
                                                         options: [],
                                                         error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        if let coordinationError {
            printDebug("ICloudDriveAlbumMarkerFile read coordination failed: \(coordinationError)")
            return nil
        }
        return data
    }

    // MARK: - Writing

    /// Writes the marker into `directory`, replacing any marker already there.
    ///
    /// The bytes go to a scratch file outside the folder first and are swapped in
    /// inside a coordinated write, so iCloud Drive never sees a partly written
    /// marker.
    public func write(toAlbumDirectory directory: URL) throws {
        let data = try encoded()
        let target = Self.url(inAlbumDirectory: directory)
        let fileManager = FileManager.default

        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target,
                                                         options: .forReplacing,
                                                         error: &coordinationError) { writeURL in
            do {
                let scratchDirectory = try fileManager.url(for: .itemReplacementDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: writeURL.deletingLastPathComponent(),
                                                           create: true)
                defer { try? fileManager.removeItem(at: scratchDirectory) }
                let scratch = scratchDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
                try data.write(to: scratch, options: .atomic)
                if fileManager.fileExists(atPath: writeURL.path) {
                    _ = try fileManager.replaceItemAt(writeURL, withItemAt: scratch)
                } else {
                    try fileManager.moveItem(at: scratch, to: writeURL)
                }
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
