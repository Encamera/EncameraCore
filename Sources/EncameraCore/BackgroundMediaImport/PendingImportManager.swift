//
//  PendingImportManager.swift
//  EncameraCore
//
//  Created for Share Extension import coordination
//

import Foundation
import Combine
import UIKit

/// Manages pending media imports from the Share Extension to the main app.
/// This class coordinates the detection and processing of media files that were
/// shared to Encamera from other apps via the Share Extension.
@MainActor
public class PendingImportManager: ObservableObject, DebugPrintable {
    
    // MARK: - Shared Instance
    
    public static let shared = PendingImportManager()
    
    // MARK: - Published Properties
    
    /// Whether there are pending imports waiting to be processed
    @Published public private(set) var hasPendingImports: Bool = false
    
    /// The count of pending media files
    @Published public private(set) var pendingCount: Int = 0
    
    /// The pending media items (loaded on demand)
    @Published public private(set) var pendingMedia: [CleartextMedia] = []
    
    /// Whether we're currently checking for pending imports
    @Published public private(set) var isChecking: Bool = false
    
    // MARK: - Private Properties
    
    private let appGroupFileAccess = AppGroupFileAccess.shared
    private var cancellables = Set<AnyCancellable>()
    
    /// UserDefaults key for tracking when imports were last added (used by extension)
    private static let lastImportTimestampKey = "PendingImport_LastTimestamp"
    
    /// UserDefaults key for tracking pending count (set by extension for quick access)
    private static let pendingCountKey = "PendingImport_Count"
    
    /// Shared UserDefaults suite for App Group
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: UserDefaultUtils.appGroup)
    }
    
    // MARK: - Initialization
    
    public init() {
        setupNotificationObservers()
    }
    
    // MARK: - Public API
    
    /// Checks for pending imports from the Share Extension
    /// Call this when the app becomes active or when triggered by a deep link
    public func checkForPendingImports() async {
        guard !isChecking else {
            printDebug("Already checking for pending imports, skipping")
            return
        }
        
        isChecking = true
        defer { isChecking = false }
        
        printDebug("Checking for pending imports from Share Extension...")
        
        let count = appGroupFileAccess.pendingMediaCount()
        let hadPending = hasPendingImports
        
        pendingCount = count
        hasPendingImports = count > 0
        
        if hasPendingImports {
            printDebug("Found \(count) pending media files")
        } else if hadPending {
            printDebug("No more pending imports")
        }
    }
    
    /// Loads all pending media items (call when showing the import UI)
    public func loadPendingMedia() async {
        printDebug("Loading pending media items...")
        let media = await appGroupFileAccess.enumerateMedia()
        pendingMedia = media
        pendingCount = media.count
        hasPendingImports = !media.isEmpty
        printDebug("Loaded \(media.count) pending media items")
    }
    
    /// Imports all pending media to the specified album
    /// - Parameters:
    ///   - albumId: The album ID to import media into
    ///   - albumManager: The album manager for configuration
    /// - Returns: The number of successfully imported items
    public func importPendingMedia(
        toAlbumId albumId: String,
        albumManager: AlbumManaging
    ) async throws -> Int {
        printDebug("Starting import of pending media to album: \(albumId)")
        
        // Ensure we have the latest pending media
        await loadPendingMedia()
        
        guard !pendingMedia.isEmpty else {
            printDebug("No pending media to import")
            return 0
        }
        
        let mediaToImport = pendingMedia
        
        // Use the existing BackgroundMediaImportManager for the actual import
        try await BackgroundMediaImportManager.shared.startImport(
            media: mediaToImport,
            albumId: albumId,
            source: .shareExtension,
            assetIdentifiers: []
        )
        
        // Clean up the app group container after starting the import
        // Note: The files will be copied during import, so we can clean up
        await cleanupAfterImport(importedMedia: mediaToImport)
        
        return mediaToImport.count
    }
    
    /// Cancels/dismisses pending imports without importing them
    public func cancelPendingImports() async throws {
        printDebug("Cancelling pending imports - deleting files from app group")
        
        try await appGroupFileAccess.deleteAllMedia()
        
        pendingMedia = []
        pendingCount = 0
        hasPendingImports = false
        
        // Clear the metadata in shared UserDefaults
        clearPendingMetadata()
        
        printDebug("Pending imports cancelled and cleaned up")
    }
    
    /// Deletes specific pending media items
    public func deletePendingMedia(_ media: [CleartextMedia]) async throws {
        try await appGroupFileAccess.delete(mediaList: media)
        
        // Reload to update counts
        await loadPendingMedia()
    }
    
    // MARK: - Metadata Management (Used by Share Extension)
    
    /// Records that new media was added to the pending queue
    /// Call this from the Share Extension after saving files
    public func recordPendingImport(count: Int) {
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: Self.lastImportTimestampKey)
        
        let currentCount = sharedDefaults?.integer(forKey: Self.pendingCountKey) ?? 0
        sharedDefaults?.set(currentCount + count, forKey: Self.pendingCountKey)
        sharedDefaults?.synchronize()
        
        printDebug("Recorded \(count) new pending imports (total: \(currentCount + count))")
    }
    
    /// Gets the timestamp of the last pending import
    public func lastPendingImportTimestamp() -> Date? {
        guard let timestamp = sharedDefaults?.double(forKey: Self.lastImportTimestampKey),
              timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    /// Clears the pending import metadata
    private func clearPendingMetadata() {
        sharedDefaults?.removeObject(forKey: Self.lastImportTimestampKey)
        sharedDefaults?.removeObject(forKey: Self.pendingCountKey)
        sharedDefaults?.synchronize()
    }
    
    // MARK: - Private Methods
    
    private func cleanupAfterImport(importedMedia: [CleartextMedia]) async {
        printDebug("Cleaning up \(importedMedia.count) imported files from app group")
        
        do {
            try await appGroupFileAccess.delete(mediaList: importedMedia)
            printDebug("Successfully cleaned up imported files")
        } catch {
            printDebug("WARNING: Failed to clean up some imported files: \(error)")
        }
        
        // Reset state
        pendingMedia = []
        pendingCount = 0
        hasPendingImports = false
        clearPendingMetadata()
    }
    
    private func setupNotificationObservers() {
        // Check for pending imports when app becomes active
        NotificationUtils.didBecomeActivePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkForPendingImports()
                }
            }
            .store(in: &cancellables)
        
        // Also check when app enters foreground
        NotificationUtils.willEnterForegroundPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.checkForPendingImports()
                }
            }
            .store(in: &cancellables)
    }
}

