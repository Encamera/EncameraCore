//
//  MediaImportHandler.swift
//  EncameraCore
//
//  Created by Alexander Freas on 10.12.25.
//

import Foundation
import BackgroundTasks
import Combine
import UIKit

// MARK: - Import Media Source

/// Represents the source of media for an import operation.
/// Supports both preloaded media (already in memory) and streaming from selection results.
enum ImportMediaSource {
    /// Media that has already been loaded into memory (e.g., from Files app or Share Extension)
    case preloaded([CleartextMedia])
    
    /// Media selection results that need to be loaded on-demand (e.g., from Photo Picker)
    /// Enables memory-efficient streaming where items are loaded one at a time
    case streaming([MediaSelectionResult])
    
    var count: Int {
        switch self {
        case .preloaded(let media):
            // Count unique media IDs (live photos have same ID for image+video)
            return Set(media.map { $0.id }).count
        case .streaming(let results):
            return results.count
        }
    }
}

// MARK: - Media Import Handler

/// Handles all import-specific logic for importing media into encrypted albums.
/// Uses BackgroundTaskManager for task state management.
@MainActor
public class MediaImportHandler: DebugPrintable {
    
    public static let shared = MediaImportHandler()
    
    // MARK: - Dependencies
    
    private let taskManager: BackgroundTaskManager
    private var albumManager: AlbumManaging?
    
    // MARK: - Private Properties
    
    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    private var currentImportTask: Task<Void, Error>?
    private let mediaLoader = MediaLoaderService()
    
    // MARK: - Initialization
    
    public init(taskManager: BackgroundTaskManager = .shared) {
        self.taskManager = taskManager
        setupNotificationObservers()
    }
    
    // MARK: - Public Configuration
    
    public func configure(albumManager: AlbumManaging) {
        printDebug("Configuring MediaImportHandler with albumManager")
        self.albumManager = albumManager
    }
    
    // MARK: - Public Import API
    
    /// High-level API: Start import directly from MediaSelectionResults (PHAssets or PHPickerResults)
    /// This handles the complete flow: load each item, import it, then cleanup its temp files atomically.
    /// Uses streaming mode for memory efficiency - items are loaded one at a time.
    /// Returns a summary of successful and failed imports.
    @discardableResult
    public func startImport(results: [MediaSelectionResult], albumId: String, source: ImportSource) async throws -> (success: Int, failure: Int) {
        printDebug("Starting import from \(results.count) MediaSelectionResults to album: \(albumId)")
        
        // Validate configuration upfront
        _ = try validateAndGetAlbum(albumId: albumId)
        
        // Create and register the task using shared helper
        let task = createAndRegisterTask(
            totalFiles: results.count,
            albumId: albumId,
            source: source
        )
        
        // Execute using unified infrastructure with streaming mode
        return try await executeImportTask(task, mediaSource: .streaming(results))
    }
    
    /// Start import from preloaded media (e.g., from Files app or Share Extension)
    public func startImport(media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = [], userBatchId: String? = nil) async throws {
        printDebug("Starting import for \(media.count) media items to album: \(albumId) from source: \(source.rawValue) with \(assetIdentifiers.count) asset identifiers")
        
        // Validate configuration upfront
        _ = try validateAndGetAlbum(albumId: albumId)
        
        // Log details about each media item (first 5 for brevity)
        for (index, mediaItem) in media.prefix(5).enumerated() {
            printDebug("Media item \(index): id=\(mediaItem.id)")
            if case .url(let url) = mediaItem.source {
                printDebug("  - URL: \(url.path)")
                printDebug("  - File exists: \(FileManager.default.fileExists(atPath: url.path))")
                printDebug("  - Is temp file: \(url.path.contains("/tmp/"))")
            }
        }
        if media.count > 5 {
            printDebug("... and \(media.count - 5) more media items")
        }
        
        // Create and register the task using shared helper
        let task = createAndRegisterTask(
            media: media,
            albumId: albumId,
            source: source,
            assetIdentifiers: assetIdentifiers,
            userBatchId: userBatchId
        )
        
        // Execute using unified infrastructure with preloaded mode
        try await executeImportTask(task, mediaSource: .preloaded(media))
    }
    
    /// Pauses an in-progress import task
    public func pauseImport(taskId: String) {
        printDebug("Pausing import task: \(taskId)")
        guard taskManager.task(withId: taskId) != nil else {
            printDebug("Failed to find task to pause: \(taskId)")
            return
        }
        
        taskManager.markTaskPaused(taskId: taskId)
        currentImportTask?.cancel()
    }
    
    /// Resumes a paused import task
    public func resumeImport(taskId: String) async throws {
        printDebug("Resuming import task: \(taskId)")
        guard let task = taskManager.task(withId: taskId) as? ImportTask,
              task.progress.state == .paused else {
            printDebug("Failed to find paused task to resume: \(taskId)")
            return
        }
        
        try await executeImportTask(task)
    }
    
    /// Cancels an import task - delegates to BackgroundTaskManager
    public func cancelImport(taskId: String) {
        printDebug("Cancelling import task: \(taskId)")
        taskManager.cancelTask(taskId: taskId)
    }
    
    // MARK: - Task Creation
    
    /// Creates and registers a new import task with the manager.
    private func createAndRegisterTask(
        media: [CleartextMedia] = [],
        totalFiles: Int? = nil,
        albumId: String,
        source: ImportSource,
        assetIdentifiers: [String] = [],
        userBatchId: String? = nil
    ) -> ImportTask {
        let taskId = UUID().uuidString
        let batchId = userBatchId ?? UUID().uuidString
        
        let task: ImportTask
        if media.isEmpty, let total = totalFiles {
            // Streaming mode: create task with known count but no media yet
            task = ImportTask(id: taskId, totalFiles: total, albumId: albumId, source: source, userBatchId: batchId)
        } else {
            // Preloaded mode: create task with media
            task = ImportTask(id: taskId, media: media, albumId: albumId, source: source, assetIdentifiers: assetIdentifiers, userBatchId: batchId)
        }
        
        taskManager.addTask(task)
        
        // Register cancellation handler so BackgroundTaskManager can cancel this task
        taskManager.registerCancellationHandler(for: taskId) { [weak self] in
            self?.printDebug("Cancellation handler invoked for task: \(taskId)")
            self?.currentImportTask?.cancel()
        }
        
        printDebug("Created import task with ID: \(taskId) for \(task.progress.totalFiles) items")
        
        return task
    }
    
    // MARK: - Validation
    
    /// Validates album configuration and returns the album if valid.
    private func validateAndGetAlbum(albumId: String) throws -> Album {
        guard let albumManager = albumManager else {
            printDebug("Failed to start import - albumManager not configured")
            throw BackgroundImportError.configurationError
        }
        
        albumManager.loadAlbumsFromFilesystem()
        guard let album = albumManager.albums.first(where: { $0.id == albumId }) else {
            printDebug("Failed to start import - album not found: \(albumId)")
            throw BackgroundImportError.configurationError
        }
        
        return album
    }
    
    // MARK: - Import Execution
    
    /// Unified import task execution that supports both preloaded and streaming modes.
    @discardableResult
    private func executeImportTask(_ task: ImportTask, mediaSource: ImportMediaSource) async throws -> (success: Int, failure: Int) {
        printDebug("Executing import task: \(task.id) with source: \(mediaSource.count) items")
        
        let album = try validateAndGetAlbum(albumId: task.albumId)
        guard let albumManager = albumManager else {
            throw BackgroundImportError.configurationError
        }
        
        taskManager.markTaskRunning(taskId: task.id)
        
        printDebug("Starting background task for import: \(task.id)")
        startBackgroundTask()
        taskManager.resetTimeEstimationState()
        
        var successCount = 0
        var failureCount = 0
        var collectedAssetIdentifiers: [String] = []
        var wasCancelled = false
        
        currentImportTask = Task {
            let fileAccess = await InteractableMediaDiskAccess(for: album, albumManager: albumManager)
            
            switch mediaSource {
            case .preloaded(let media):
                try await performBatchImport(task: task, media: media, fileAccess: fileAccess)
                successCount = task.uniqueMediaCount
                // For preloaded imports, asset identifiers are already set on the task
                collectedAssetIdentifiers = task.assetIdentifiers
                
            case .streaming(let results):
                let counts = try await performStreamingImport(task: task, results: results, fileAccess: fileAccess)
                successCount = counts.success
                failureCount = counts.failure
                collectedAssetIdentifiers = counts.assetIdentifiers
                
                // Check if we were cancelled (fewer successes than total results)
                // This happens when the streaming loop breaks early due to cancellation
                if successCount + failureCount < results.count {
                    wasCancelled = true
                }
            }
        }
        
        do {
            try await currentImportTask?.value
            
            await MainActor.run {
                // Check if the task was cancelled during streaming (early exit from loop)
                if wasCancelled {
                    self.printDebug("Streaming import was cancelled with \(collectedAssetIdentifiers.count) partial imports")
                    self.taskManager.finalizeTaskCancelled(taskId: task.id, assetIdentifiers: collectedAssetIdentifiers)
                } else {
                    self.taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: mediaSource.count, assetIdentifiers: collectedAssetIdentifiers)
                }
                self.endBackgroundTask()
                self.cleanupTempFilesIfSafe()
            }
        } catch is CancellationError {
            // Task was cancelled (typically batch imports via Task.checkCancellation())
            // For preloaded imports, use the task's existing asset identifiers
            let partialIdentifiers = task.assetIdentifiers
            await MainActor.run {
                self.printDebug("Batch import was cancelled with \(partialIdentifiers.count) asset identifiers")
                self.taskManager.finalizeTaskCancelled(taskId: task.id, assetIdentifiers: partialIdentifiers)
                self.endBackgroundTask()
                self.cleanupTempFilesIfSafe()
            }
            // Don't re-throw cancellation errors - the task is properly finalized
        } catch {
            await MainActor.run {
                self.taskManager.finalizeTaskFailed(taskId: task.id, error: error)
                self.endBackgroundTask()
                self.cleanupTempFilesIfSafe()
            }
            throw error
        }
        
        return (successCount, failureCount)
    }
    
    /// Legacy overload for backward compatibility with resumeImport
    private func executeImportTask(_ task: ImportTask) async throws {
        try await executeImportTask(task, mediaSource: .preloaded(task.media))
    }
    
    /// Performs batch import for preloaded media with concurrent processing.
    private func performBatchImport(task: ImportTask, media: [CleartextMedia], fileAccess: FileAccess) async throws {
        printDebug("Performing batch import for task: \(task.id)")
        let startTime = Date()
        var processedGroups = 0
        
        let mediaGroups = groupMediaById(media)
        let totalGroups = mediaGroups.count
        printDebug("Grouped \(media.count) media items into \(totalGroups) groups (live photos count as 1)")
        
        let batchSize = 3
        let batches = mediaGroups.chunked(into: batchSize)
        printDebug("Processing \(batches.count) batches of size \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            printDebug("Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) media groups")
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (groupIndex, mediaGroup) in batch.enumerated() {
                    group.addTask {
                        let globalIndex = batchIndex * batchSize + groupIndex
                        try await self.processMediaGroup(
                            mediaGroup: mediaGroup,
                            fileAccess: fileAccess,
                            task: task,
                            groupIndex: globalIndex,
                            totalGroups: totalGroups,
                            startTime: startTime,
                            processedGroups: processedGroups
                        )
                    }
                }
                
                try await group.waitForAll()
            }
            
            processedGroups += batch.count
            printDebug("Completed batch \(batchIndex + 1)/\(batches.count), total processed: \(processedGroups)/\(totalGroups)")
        }
        
        printDebug("Batch import completed for task: \(task.id)")
    }
    
    /// Performs streaming import for MediaSelectionResults with sequential processing.
    private func performStreamingImport(
        task: ImportTask,
        results: [MediaSelectionResult],
        fileAccess: FileAccess
    ) async throws -> (success: Int, failure: Int, assetIdentifiers: [String]) {
        printDebug("Performing streaming import for task: \(task.id) with \(results.count) results")
        let startTime = Date()
        var processedCount = 0
        var successCount = 0
        var failureCount = 0
        var collectedAssetIdentifiers: [String] = []
        
        for (index, result) in results.enumerated() {
            // Check for cancellation
            guard let currentTask = await MainActor.run(body: { taskManager.task(withId: task.id) }),
                  await MainActor.run(body: { currentTask.progress.state == .running }) else {
                printDebug("Import task \(task.id) was cancelled or not found, stopping")
                break
            }
            
            printDebug("📄 Processing item \(index + 1)/\(results.count)")
            
            do {
                let (media, assetId) = try await mediaLoader.loadSingleMedia(from: result)
                
                try await importSingleItem(
                    mediaGroup: media,
                    fileAccess: fileAccess,
                    task: task,
                    groupIndex: index,
                    totalGroups: results.count,
                    startTime: startTime,
                    processedGroups: processedCount
                )
                
                if task.source.canDeleteTempFilesAfterImport {
                    deleteTempFiles(for: media)
                }
                
                // Collect asset identifier for successful imports
                if let assetId = assetId {
                    collectedAssetIdentifiers.append(assetId)
                }
                
                successCount += 1
                processedCount += 1
                printDebug("✅ Successfully imported item \(index + 1)/\(results.count)")
                
            } catch {
                failureCount += 1
                printDebug("❌ Error processing item \(index + 1): \(error)")
            }
        }
        
        printDebug("📈 Streaming import complete - Processed: \(processedCount)/\(results.count) (Success: \(successCount), Failed: \(failureCount), AssetIDs: \(collectedAssetIdentifiers.count))")
        return (successCount, failureCount, collectedAssetIdentifiers)
    }
    
    // MARK: - Media Processing
    
    /// Helper to process a single item (load -> save -> progress)
    private func importSingleItem(
        mediaGroup: [CleartextMedia],
        fileAccess: FileAccess,
        task: ImportTask,
        groupIndex: Int,
        totalGroups: Int,
        startTime: Date,
        processedGroups: Int
    ) async throws {
        let mediaId = mediaGroup.first?.id ?? "unknown"
        let interactableMedia = try InteractableMedia(underlyingMedia: mediaGroup)
        
        try await saveMedia(
            interactableMedia,
            mediaGroup: mediaGroup,
            mediaId: mediaId,
            fileAccess: fileAccess,
            task: task,
            groupIndex: groupIndex,
            totalGroups: totalGroups,
            startTime: startTime,
            processedGroups: processedGroups
        )
    }
    
    /// Processes a group of CleartextMedia items as a single InteractableMedia.
    private func processMediaGroup(
        mediaGroup: [CleartextMedia],
        fileAccess: FileAccess,
        task: ImportTask,
        groupIndex: Int,
        totalGroups: Int,
        startTime: Date,
        processedGroups: Int
    ) async throws {
        let mediaId = mediaGroup.first?.id ?? "unknown"
        let isLivePhoto = mediaGroup.count > 1
        printDebug("Processing \(isLivePhoto ? "live photo" : "media") \(groupIndex + 1)/\(totalGroups): \(mediaId) (\(mediaGroup.count) component(s))")
        
        logSourceFileStatus(for: mediaGroup)
        
        try await importSingleItem(
            mediaGroup: mediaGroup,
            fileAccess: fileAccess,
            task: task,
            groupIndex: groupIndex,
            totalGroups: totalGroups,
            startTime: startTime,
            processedGroups: processedGroups
        )
        
        printDebug("Successfully saved \(isLivePhoto ? "live photo" : "media") \(groupIndex + 1)/\(totalGroups): \(mediaId)")
    }
    
    /// Saves the InteractableMedia to disk and updates progress.
    private func saveMedia(
        _ interactableMedia: InteractableMedia<CleartextMedia>,
        mediaGroup: [CleartextMedia],
        mediaId: String,
        fileAccess: FileAccess,
        task: ImportTask,
        groupIndex: Int,
        totalGroups: Int,
        startTime: Date,
        processedGroups: Int
    ) async throws {
        do {
            try await fileAccess.save(media: interactableMedia) { fileProgress in
                Task { @MainActor in
                    self.updateImportProgress(
                        task: task,
                        groupIndex: groupIndex,
                        totalGroups: totalGroups,
                        fileProgress: fileProgress,
                        processedGroups: processedGroups,
                        startTime: startTime,
                        mediaId: mediaId
                    )
                }
            }
        } catch {
            logSaveError(error, mediaGroup: mediaGroup, mediaId: mediaId)
            throw error
        }
    }
    
    /// Updates progress during import
    private func updateImportProgress(
        task: ImportTask,
        groupIndex: Int,
        totalGroups: Int,
        fileProgress: Double,
        processedGroups: Int,
        startTime: Date,
        mediaId: String
    ) {
        let overallProgress = (Double(processedGroups) + fileProgress) / Double(totalGroups)
        let estimatedTimeRemaining = taskManager.calculateEstimatedTime(startTime: startTime, progress: overallProgress)
        
        let progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: groupIndex,
            totalFiles: totalGroups,
            currentFileProgress: fileProgress,
            overallProgress: overallProgress,
            currentFileName: mediaId,
            state: .running,
            estimatedTimeRemaining: estimatedTimeRemaining
        )
        
        taskManager.updateTaskProgress(taskId: task.id, progress: progress)
    }
    
    // MARK: - Helper Methods
    
    /// Groups CleartextMedia items by their ID so that live photo components are processed together.
    private func groupMediaById(_ media: [CleartextMedia]) -> [[CleartextMedia]] {
        var groups: [String: [CleartextMedia]] = [:]
        for item in media {
            groups[item.id, default: []].append(item)
        }
        var seen = Set<String>()
        return media.compactMap { item -> [CleartextMedia]? in
            guard !seen.contains(item.id) else { return nil }
            seen.insert(item.id)
            return groups[item.id]
        }
    }
    
    /// Logs source file status for debugging temp file issues.
    private func logSourceFileStatus(for mediaGroup: [CleartextMedia]) {
        for media in mediaGroup {
            guard case .url(let sourceURL) = media.source else { continue }
            
            let fileManager = FileManager.default
            let exists = fileManager.fileExists(atPath: sourceURL.path)
            printDebug("Source: \(sourceURL.lastPathComponent), exists: \(exists)")
            
            if !exists {
                printDebug("WARNING: Source file missing at \(sourceURL.path)")
            } else if sourceURL.path.contains("/tmp/") {
                printDebug("Note: File is in temp directory")
            }
        }
    }
    
    /// Logs detailed error information when save fails.
    private func logSaveError(_ error: Error, mediaGroup: [CleartextMedia], mediaId: String) {
        printDebug("Failed to save media \(mediaId): \(error)")
        
        if let nsError = error as NSError? {
            printDebug("Error domain: \(nsError.domain), code: \(nsError.code)")
            
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 4 {
                printDebug("File not found - temp files may have been cleaned up")
                for media in mediaGroup {
                    if case .url(let url) = media.source {
                        printDebug("Post-error check - \(url.lastPathComponent) exists: \(FileManager.default.fileExists(atPath: url.path))")
                    }
                }
            }
        }
    }
    
    /// Deletes temporary files for the given media items.
    private func deleteTempFiles(for media: [CleartextMedia]) {
        let tempDirPath = URL.tempMediaDirectory.path
        for item in media {
            if case .url(let url) = item.source {
                if url.path.hasPrefix(tempDirPath) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        printDebug("🗑️ Deleted temp file: \(url.lastPathComponent)")
                    } catch {
                        printDebug("⚠️ Failed to delete temp file \(url.lastPathComponent): \(error)")
                    }
                }
            }
        }
    }
    
    private func cleanupTempFilesIfSafe() {
        printDebug("cleanupTempFilesIfSafe() called")
        
        let hasActiveImports = taskManager.currentTasks.contains { task in
            task.progress.state == .running
        }
        
        printDebug("Current tasks count: \(taskManager.currentTasks.count)")
        for (index, task) in taskManager.currentTasks.enumerated() {
            if let importTask = task as? ImportTask {
                printDebug("Task \(index): id=\(importTask.id), state=\(importTask.progress.state), source=\(importTask.source.rawValue)")
            }
        }
        
        if !hasActiveImports {
            printDebug("No active imports - cleaning up temporary files")
            TempFileAccess.cleanupTemporaryFiles()
            printDebug("TempFileAccess.cleanupTemporaryFiles() completed")
        } else {
            let activeCount = taskManager.currentTasks.filter { $0.progress.state == .running }.count
            printDebug("Active imports detected (\(activeCount)) - keeping temp files")
        }
    }
    
    // MARK: - Background Task Management
    
    private func startBackgroundTask() {
        printDebug("Starting UIBackgroundTask")
        endBackgroundTask()
        
        activeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MediaImport") {
            self.printDebug("UIBackgroundTask expiration handler called - time limit reached")
            self.endBackgroundTask()
        }
        
        if activeBackgroundTask == .invalid {
            printDebug("Failed to start UIBackgroundTask - got invalid identifier")
        } else {
            printDebug("UIBackgroundTask started with identifier: \(activeBackgroundTask.rawValue)")
        }
    }
    
    private func endBackgroundTask() {
        if activeBackgroundTask != .invalid {
            printDebug("Ending UIBackgroundTask with identifier: \(activeBackgroundTask.rawValue)")
            UIApplication.shared.endBackgroundTask(activeBackgroundTask)
            activeBackgroundTask = .invalid
        } else {
            printDebug("No active UIBackgroundTask to end")
        }
    }
    
    // MARK: - Notification Observers
    
    private func setupNotificationObservers() {
        printDebug("Setting up notification observers for background/foreground transitions")
        
        NotificationUtils.willEnterForegroundPublisher
            .sink { [weak self] _ in
                self?.printDebug("App will enter foreground - refreshing task states")
                self?.printDebug("Current tasks: \(self?.taskManager.currentTasks.count ?? 0)")
                Task { @MainActor in
                    self?.taskManager.updateOverallProgress()
                    self?.cleanupTempFilesIfSafe()
                }
            }
            .store(in: &cancellables)
        
        NotificationUtils.willResignActivePublisher
            .sink { [weak self] _ in
                self?.printDebug("App will resign active - preparing for background")
                self?.printDebug("WARNING: Temp files may be cleaned up soon!")
            }
            .store(in: &cancellables)
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
