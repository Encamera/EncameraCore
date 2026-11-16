//
//  AppGroupFileAccess.swift
//  EncameraCore
//
//  Created by Alexander Freas on 11.05.23.
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Manages file access to the shared App Group container for sharing media between
/// the Share Extension and the main app.
public class AppGroupFileAccess: DebugPrintable {
    
    // MARK: - Shared Instance
    
    public static let shared = AppGroupFileAccess()
    
    // MARK: - Properties
    
    /// Set by tests to stage media in a scratch directory instead of the App Group.
    private let directoryOverride: URL?

    /// The root URL for the shared container's import directory
    public var importDirectoryURL: URL? {
        if let directoryOverride {
            return directoryOverride
        }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UserDefaultUtils.appGroup) else {
            printDebug("ERROR: Could not get App Group container URL for identifier: \(UserDefaultUtils.appGroup)")
            return nil
        }
        return containerURL.appendingPathComponent("ImportImages")
    }
    
    // MARK: - Initialization
    
    public init() {
        directoryOverride = nil
        initializeDirectoryIfNeeded()
    }

    init(importDirectoryURL: URL) {
        directoryOverride = importDirectoryURL
        initializeDirectoryIfNeeded()
    }
    
    // MARK: - Directory Management
    
    /// Ensures the import directory exists
    private func initializeDirectoryIfNeeded() {
        guard let url = importDirectoryURL else { return }
        
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                printDebug("Created import directory at: \(url.path)")
            } catch {
                printDebug("ERROR: Failed to create import directory: \(error)")
            }
        }
    }
    
    // MARK: - Saving Media
    
    /// Saves cleartext media to the App Group container
    /// - Parameters:
    ///   - media: The cleartext media to save
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: The URL where the file was saved
    @discardableResult
    public func save(media: CleartextMedia, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let containerURL = importDirectoryURL else {
            throw AppGroupFileAccessError.containerNotAvailable
        }
        
        initializeDirectoryIfNeeded()
        
        switch media.source {
        case .data(let data):
            let filename = "\(media.id).jpeg"
            let destinationURL = containerURL.appendingPathComponent(filename)
            
            printDebug("Saving media data to: \(destinationURL.path)")
            try data.write(to: destinationURL)
            try markStaged(destinationURL)
            progress(1.0)
            return destinationURL
            
        case .url(let sourceURL):
            let fileExtension = normalizeFileExtension(sourceURL.pathExtension)
            let filename = "\(media.id).\(fileExtension)"
            let destinationURL = containerURL.appendingPathComponent(filename)
            
            printDebug("Copying media from \(sourceURL.path) to \(destinationURL.path)")
            
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try markStaged(destinationURL)
            progress(1.0)
            return destinationURL
        }
    }
    
    /// Stamps a just-saved file with the time it was staged and, on iOS, keeps it
    /// encrypted while the device is locked. The modification date is the staged
    /// time because a copy keeps the source's dates; the creation date is left as
    /// the media's own.
    private func markStaged(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.modificationDate: Date()]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Lets the files be read while the device is locked, so an import the user
    /// started keeps going if they lock the phone before it finishes.
    public func allowReadingWhileLocked(_ urls: [URL]) {
        #if os(iOS)
        for url in urls {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                printDebug("WARNING: Could not relax protection on \(url.lastPathComponent): \(error)")
            }
        }
        #endif
    }

    /// Normalizes file extensions for consistency
    private func normalizeFileExtension(_ ext: String) -> String {
        let lowercased = ext.lowercased()
        switch lowercased {
        case "jpg":
            return "jpeg"
        default:
            return lowercased
        }
    }
    
    // MARK: - Enumerating Media
    
    /// Returns all pending media files in the import directory
    public func enumerateMedia() async -> [CleartextMedia] {
        guard let containerURL = importDirectoryURL else {
            printDebug("ERROR: Container URL not available for enumeration")
            return []
        }
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            
            let filteredURLs = fileURLs.filter { url in
                MediaType.from(url: url) != .unknown
            }

            let media = filteredURLs.map { url -> CleartextMedia in
                var cleartextMedia = CleartextMedia(source: url)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let creationDate = attributes[.creationDate] as? Date {
                    cleartextMedia.timestamp = creationDate
                }
                return cleartextMedia
            }
            
            printDebug("Found \(media.count) pending media files in app group container")
            return media.sorted { ($0.timestamp ?? Date.distantPast) > ($1.timestamp ?? Date.distantPast) }
            
        } catch {
            printDebug("ERROR: Could not enumerate contents of directory: \(error)")
            return []
        }
    }
    
    /// Returns the count of pending media files without loading them all
    public func pendingMediaCount() -> Int {
        pendingMediaURLs().count
    }

    /// The pending media files, without reading them.
    public func pendingMediaURLs() -> [URL] {
        guard let containerURL = importDirectoryURL else { return [] }

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            return fileURLs.filter { url in
                MediaType.from(url: url) != .unknown
            }
        } catch {
            return []
        }
    }
    
    // MARK: - Deleting Media
    
    /// Deletes a specific media file from the import directory
    public func delete(media: CleartextMedia) async throws {
        guard case .url(let url) = media.source else {
            throw AppGroupFileAccessError.invalidMediaSource
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            printDebug("File already deleted or doesn't exist: \(url.path)")
            return
        }
        
        try FileManager.default.removeItem(at: url)
        printDebug("Deleted media file: \(url.lastPathComponent)")
    }
    
    /// Deletes multiple media files
    public func delete(mediaList: [CleartextMedia]) async throws {
        for media in mediaList {
            try await delete(media: media)
        }
    }
    
    /// Deletes pending media staged before `cutoff`, leaving the files in
    /// `excluded` alone.
    /// - Returns: How many files were deleted.
    @discardableResult
    public func deleteMedia(stagedBefore cutoff: Date, excluding excluded: Set<URL> = []) -> Int {
        let excludedPaths = Set(excluded.map(\.standardizedFileURL.path))
        var deleted = 0
        for url in pendingMediaURLs() where !excludedPaths.contains(url.standardizedFileURL.path) {
            guard let stagedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  stagedAt < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                deleted += 1
            } catch {
                printDebug("WARNING: Could not delete expired pending media \(url.lastPathComponent): \(error)")
            }
        }
        if deleted > 0 {
            printDebug("Deleted \(deleted) pending media files staged before \(cutoff)")
        }
        return deleted
    }

    /// Deletes all media files in the import directory
    public func deleteAllMedia() async throws {
        guard let containerURL = importDirectoryURL else {
            throw AppGroupFileAccessError.containerNotAvailable
        }
        
        let media = await enumerateMedia()
        
        for item in media {
            try await delete(media: item)
        }
        
        printDebug("Deleted all \(media.count) pending media files")
    }
    
    /// Clears the entire import directory (including any non-media files)
    public func clearImportDirectory() throws {
        guard let containerURL = importDirectoryURL else {
            throw AppGroupFileAccessError.containerNotAvailable
        }
        
        if FileManager.default.fileExists(atPath: containerURL.path) {
            try FileManager.default.removeItem(at: containerURL)
            printDebug("Cleared import directory")
        }
        
        initializeDirectoryIfNeeded()
    }
}

// MARK: - Errors

public enum AppGroupFileAccessError: Error, LocalizedError {
    case containerNotAvailable
    case invalidMediaSource
    case fileNotFound
    case saveFailed(underlyingError: Error)
    
    public var errorDescription: String? {
        switch self {
        case .containerNotAvailable:
            return "App Group container is not available"
        case .invalidMediaSource:
            return "Invalid media source"
        case .fileNotFound:
            return "File not found"
        case .saveFailed(let error):
            return "Failed to save file: \(error.localizedDescription)"
        }
    }
}
