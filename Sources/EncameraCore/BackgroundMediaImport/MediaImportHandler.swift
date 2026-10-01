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
            return Set(media.map { $0.id }).count
        case .streaming(let results):
            return results.count
        }
    }
}

// MARK: - Import Result Summary

/// Details of a single media group that failed to import. Carries the media id
/// and the underlying error so callers can surface a reason to the user
/// and classify it for analytics.
///
/// `@unchecked Sendable`: the wrapped `Error` values here are immutable enum/value
/// errors, so they are safe to hand back through a throwing task group.
public struct ImportItemFailure: @unchecked Sendable {
    public let id: String
    public let error: Error

    public init(id: String, error: Error) {
        self.id = id
        self.error = error
    }
}

/// The outcome of an import run: how many media groups succeeded, how many failed,
/// and the per-item failure details.
public struct ImportResultSummary: Sendable {
    public let success: Int
    public let failure: Int
    public let failedItems: [ImportItemFailure]
    /// The run stopped early because the device ran out of space.
    public let stoppedForSpace: Bool
    /// Items never tried because the run stopped for space.
    public let notAttemptedCount: Int

    public init(success: Int, failure: Int, failedItems: [ImportItemFailure] = [], stoppedForSpace: Bool = false, notAttemptedCount: Int = 0) {
        self.success = success
        self.failure = failure
        self.failedItems = failedItems
        self.stoppedForSpace = stoppedForSpace
        self.notAttemptedCount = notAttemptedCount
    }
}

/// Starts imports into an album; `MediaImportHandler` is the live one.
@MainActor
public protocol MediaImporting: AnyObject {
    func startImport(results: [MediaSelectionResult], albumId: String, source: ImportSource, plannedSizes: [Int64?]?) async throws -> ImportResultSummary
    func startImport(media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String], userBatchId: String?, plannedSizes: [Int64?]?) async throws -> ImportResultSummary
}

/// Loads one selected item into temporary cleartext files.
@MainActor
public protocol ImportMediaLoading {
    func loadSingleMedia(from result: MediaSelectionResult) async throws -> LoadedMediaItem
}

extension MediaLoaderService: ImportMediaLoading {}

/// Writes one media group into the album. Injected so tests can fail a save.
public typealias ImportSaveOperation = (
    _ fileAccess: FileAccess,
    _ media: InteractableMedia<CleartextMedia>,
    _ metadata: EncryptedFileMetadata?,
    _ progress: @escaping (Double) -> Void
) async throws -> Void

// MARK: - Media Import Handler

/// Handles all import-specific logic for importing media into encrypted albums.
/// Uses BackgroundTaskManager for task state management.
@MainActor
public class MediaImportHandler: DebugPrintable, MediaImporting {
    
    public static let shared = MediaImportHandler()
    
    // MARK: - Dependencies
    
    private let taskManager: BackgroundTaskManager
    private var albumManager: AlbumManaging?
    
    // MARK: - Private Properties
    
    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    private var currentImportTask: Task<Void, Error>?
    private let mediaLoader: ImportMediaLoading
    private let saveOperation: ImportSaveOperation
    private var freeSpace: DeviceFreeSpaceProviding
    
    // MARK: - Initialization
    
    public init(
        taskManager: BackgroundTaskManager = .shared,
        freeSpace: DeviceFreeSpaceProviding = LiveDeviceFreeSpace(),
        mediaLoader: ImportMediaLoading? = nil,
        saveOperation: ImportSaveOperation? = nil
    ) {
        self.taskManager = taskManager
        self.freeSpace = freeSpace
        self.mediaLoader = mediaLoader ?? MediaLoaderService()
        self.saveOperation = saveOperation ?? { fileAccess, media, metadata, progress in
            try await fileAccess.save(media: media, metadata: metadata, progress: progress)
        }
        setupNotificationObservers()
    }
    
    // MARK: - Public Configuration
    
    public func configure(albumManager: AlbumManaging) {
        printDebug("Configuring MediaImportHandler with albumManager")
        self.albumManager = albumManager
    }

    /// Replaces the free-space source, e.g. with a UI-test fake.
    public func configure(freeSpace: DeviceFreeSpaceProviding) {
        self.freeSpace = freeSpace
    }
    
    // MARK: - Public Import API
    
    /// High-level API: Start import directly from MediaSelectionResults (PHAssets or PHPickerResults)
    /// This handles the complete flow: load each item, import it, then cleanup its temp files atomically.
    /// Uses streaming mode for memory efficiency - items are loaded one at a time.
    /// Returns a summary of successful and failed imports.
    ///
    /// Every import stops once the device is full. `plannedSizes`, one entry per
    /// result, lets it stop before an item that won't fit rather than after its
    /// write fails.
    @discardableResult
    public func startImport(results: [MediaSelectionResult], albumId: String, source: ImportSource, plannedSizes: [Int64?]? = nil) async throws -> ImportResultSummary {
        printDebug("Starting import from \(results.count) MediaSelectionResults to album: \(albumId)")
        
        _ = try validateAndGetAlbum(albumId: albumId)
        
        let task = createAndRegisterTask(
            totalFiles: results.count,
            albumId: albumId,
            source: source
        )
        
        return try await executeImportTask(task, mediaSource: .streaming(results), plannedSizes: plannedSizes)
    }
    
    /// Start import from preloaded media (e.g., from Files app or Share Extension).
    /// Returns a summary of successful and failed imports, including per-item failure
    /// details so callers can surface skipped files to the user and to analytics.
    /// `plannedSizes` has one entry per media group (a Live Photo is one group).
    @discardableResult
    public func startImport(media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = [], userBatchId: String? = nil, plannedSizes: [Int64?]? = nil) async throws -> ImportResultSummary {
        printDebug("Starting import for \(media.count) media items to album: \(albumId) from source: \(source.rawValue) with \(assetIdentifiers.count) asset identifiers")
        
        _ = try validateAndGetAlbum(albumId: albumId)
        
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
        
        let task = createAndRegisterTask(
            media: media,
            albumId: albumId,
            source: source,
            assetIdentifiers: assetIdentifiers,
            userBatchId: userBatchId
        )
        
        return try await executeImportTask(task, mediaSource: .preloaded(media), plannedSizes: plannedSizes)
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
    
    /// Marks the batches these tasks belong to as deleted from the photo library in
    /// each album's import history, after their originals were deleted elsewhere
    /// (the progress pill).
    public func markDeletedFromLibrary(_ tasks: [ImportTask]) {
        guard let albumManager else { return }
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        for (albumId, albumTasks) in Dictionary(grouping: tasks, by: \.albumId) {
            guard let album = albums.first(where: { $0.id == albumId }) else { continue }
            let batchIds = Set(albumTasks.map { $0.userBatchId ?? $0.id })
            do {
                try AlbumImportHistory(album: album).markDeletedFromLibrary(ids: batchIds)
            } catch {
                printDebug("Could not mark import history deleted for album \(album.name): \(error)")
            }
        }
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
            task = ImportTask(id: taskId, totalFiles: total, albumId: albumId, source: source, userBatchId: batchId)
        } else {
            task = ImportTask(id: taskId, media: media, albumId: albumId, source: source, assetIdentifiers: assetIdentifiers, userBatchId: batchId)
        }
        
        taskManager.addTask(task)
        
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
        
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        guard let album = albums.first(where: { $0.id == albumId }) else {
            printDebug("Failed to start import - album not found: \(albumId)")
            throw BackgroundImportError.configurationError
        }
        
        return album
    }
    
    // MARK: - Import Execution
    
    /// Unified import task execution that supports both preloaded and streaming modes.
    @discardableResult
    private func executeImportTask(_ task: ImportTask, mediaSource: ImportMediaSource, plannedSizes: [Int64?]? = nil) async throws -> ImportResultSummary {
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
        var failedItems: [ImportItemFailure] = []
        var collectedAssetIdentifiers: [String] = []
        var wasCancelled = false
        var stoppedForSpace = false
        var notAttemptedCount = 0
        let isPreloaded: Bool
        if case .preloaded = mediaSource { isPreloaded = true } else { isPreloaded = false }

        currentImportTask = Task {
            let fileAccess = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

            switch mediaSource {
            case .preloaded(let media):
                let summary = try await performBatchImport(task: task, media: media, fileAccess: fileAccess, plannedSizes: plannedSizes)
                successCount = summary.success
                failureCount = summary.failure
                failedItems = summary.failedItems
                stoppedForSpace = summary.stoppedForSpace
                notAttemptedCount = summary.notAttemptedCount
                collectedAssetIdentifiers = task.assetIdentifiers

            case .streaming(let results):
                let outcome = try await performStreamingImport(task: task, results: results, fileAccess: fileAccess, plannedSizes: plannedSizes)
                successCount = outcome.summary.success
                failureCount = outcome.summary.failure
                failedItems = outcome.summary.failedItems
                stoppedForSpace = outcome.summary.stoppedForSpace
                notAttemptedCount = outcome.summary.notAttemptedCount
                collectedAssetIdentifiers = outcome.assetIdentifiers

                if successCount + failureCount + notAttemptedCount < results.count {
                    wasCancelled = true
                }
            }
        }

        do {
            try await currentImportTask?.value

            await MainActor.run {
                if wasCancelled {
                    self.printDebug("Streaming import was cancelled with \(collectedAssetIdentifiers.count) partial imports")
                    self.taskManager.finalizeTaskCancelled(taskId: task.id, assetIdentifiers: collectedAssetIdentifiers)
                    self.recordHistory(for: task, album: album, state: .cancelled, importedCount: successCount,
                                       requestedCount: mediaSource.count, assetIdentifiers: collectedAssetIdentifiers)
                } else if stoppedForSpace {
                    self.printDebug("Import stopped for space after \(successCount) imports, \(notAttemptedCount) not attempted")
                    if successCount > 0 {
                        let identifiers = isPreloaded ? [] : collectedAssetIdentifiers
                        self.taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: successCount, assetIdentifiers: identifiers)
                        self.recordHistory(for: task, album: album, state: .completed, importedCount: successCount,
                                           requestedCount: mediaSource.count, assetIdentifiers: identifiers)
                    } else {
                        self.taskManager.finalizeTaskFailed(taskId: task.id, error: BackgroundImportError.outOfSpace)
                    }
                } else if successCount == 0 && failureCount > 0 {
                    self.printDebug("Import had \(failureCount) failures and no successes - finalizing failed")
                    self.taskManager.finalizeTaskFailed(taskId: task.id, error: BackgroundImportError.allImportsFailed(failureCount: failureCount))
                } else {
                    let completedItems = (isPreloaded && successCount > 0) ? successCount : mediaSource.count
                    self.taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: completedItems, assetIdentifiers: collectedAssetIdentifiers)
                    // Preloaded identifiers are the caller's, not per item, so once anything
                    // failed there is no telling which original did not make it in.
                    let deletableIdentifiers = isPreloaded && failureCount > 0 ? [] : collectedAssetIdentifiers
                    self.recordHistory(for: task, album: album, state: .completed, importedCount: successCount,
                                       requestedCount: mediaSource.count, assetIdentifiers: deletableIdentifiers)
                }
                self.endBackgroundTask()
                self.cleanupTempFilesIfSafe()
            }
        } catch is CancellationError {
            let partialIdentifiers = !collectedAssetIdentifiers.isEmpty ? collectedAssetIdentifiers : task.assetIdentifiers
            await MainActor.run {
                self.printDebug("Import was cancelled with \(partialIdentifiers.count) asset identifiers")
                self.taskManager.finalizeTaskCancelled(taskId: task.id, assetIdentifiers: partialIdentifiers)
                self.endBackgroundTask()
                self.cleanupTempFilesIfSafe()
            }
        } catch {
            await MainActor.run {
                self.taskManager.finalizeTaskFailed(taskId: task.id, error: error)
                self.endBackgroundTask()
                self.cleanupTempFilesIfSafe()
            }
            throw error
        }
        
        return ImportResultSummary(
            success: successCount,
            failure: failureCount,
            failedItems: failedItems,
            stoppedForSpace: stoppedForSpace,
            notAttemptedCount: notAttemptedCount
        )
    }

    /// Adds the finished batch to the album's import history. An import that
    /// brought nothing in leaves no record: there is nothing to delete.
    private func recordHistory(for task: ImportTask,
                               album: Album,
                               state: ImportHistoryRecord.State,
                               importedCount: Int,
                               requestedCount: Int,
                               assetIdentifiers: [String]) {
        guard importedCount > 0 else { return }
        let record = ImportHistoryRecord(id: task.userBatchId ?? task.id,
                                         createdAt: task.createdAt,
                                         source: task.source,
                                         importedCount: importedCount,
                                         requestedCount: requestedCount,
                                         assetIdentifiers: assetIdentifiers,
                                         state: state)
        do {
            try AlbumImportHistory(album: album).append(record)
        } catch {
            printDebug("Could not record import history for task \(task.id): \(error)")
        }
    }

    /// Legacy overload for backward compatibility with resumeImport
    private func executeImportTask(_ task: ImportTask) async throws {
        _ = try await executeImportTask(task, mediaSource: .preloaded(task.media))
    }
    
    /// Outcome of importing a single media group within a batch.
    private enum MediaGroupOutcome: Sendable {
        case success
        case failure(ImportItemFailure)
    }

    /// Performs batch import for preloaded media with concurrent processing.
    ///
    /// Fault-tolerant per media group: a group that fails to import is recorded and
    /// skipped instead of aborting the whole task, mirroring the streaming path's
    /// per-item catch. Cancellation still propagates so pause/cancel halt the import.
    /// Stops before a batch that won't fit, and after a batch in which a write
    /// ran out of space.
    private func performBatchImport(task: ImportTask, media: [CleartextMedia], fileAccess: FileAccess, plannedSizes: [Int64?]? = nil) async throws -> ImportResultSummary {
        printDebug("Performing batch import for task: \(task.id)")
        let startTime = Date()
        var processedGroups = 0
        var successCount = 0
        var failedItems: [ImportItemFailure] = []
        var stoppedForSpace = false

        let mediaGroups = groupMediaById(media)
        let totalGroups = mediaGroups.count
        printDebug("Grouped \(media.count) media items into \(totalGroups) groups (live photos count as 1)")

        let batchSize = 3
        let batches = mediaGroups.chunked(into: batchSize)
        printDebug("Processing \(batches.count) batches of size \(batchSize)")

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()

            let batchStart = batchIndex * batchSize
            let batchSizes = (batchStart..<batchStart + batch.count).map { plannedSize(at: $0, in: plannedSizes) }
            guard hasRoom(forItemSizes: batchSizes) else {
                printDebug("Not enough space for batch \(batchIndex + 1) - stopping import")
                stoppedForSpace = true
                break
            }

            printDebug("Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) media groups")

            let outcomes = try await withThrowingTaskGroup(of: MediaGroupOutcome.self) { group -> [MediaGroupOutcome] in
                for (groupIndex, mediaGroup) in batch.enumerated() {
                    group.addTask {
                        let globalIndex = batchIndex * batchSize + groupIndex
                        let mediaId = mediaGroup.first?.id ?? "unknown"
                        do {
                            try await self.processMediaGroup(
                                mediaGroup: mediaGroup,
                                fileAccess: fileAccess,
                                task: task,
                                groupIndex: globalIndex,
                                totalGroups: totalGroups,
                                startTime: startTime,
                                processedGroups: processedGroups
                            )
                            return .success
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            self.printDebug("❌ Skipping media \(mediaId): \(error)")
                            return .failure(ImportItemFailure(id: mediaId, error: error))
                        }
                    }
                }

                var collected: [MediaGroupOutcome] = []
                for try await outcome in group {
                    collected.append(outcome)
                }
                return collected
            }

            for outcome in outcomes {
                switch outcome {
                case .success:
                    successCount += 1
                case .failure(let failure):
                    failedItems.append(failure)
                    if ImportSkipReason.isOutOfSpace(failure.error) {
                        stoppedForSpace = true
                    }
                }
            }

            processedGroups += batch.count
            printDebug("Completed batch \(batchIndex + 1)/\(batches.count), total processed: \(processedGroups)/\(totalGroups)")

            if stoppedForSpace {
                printDebug("A write ran out of space - stopping import")
                break
            }
        }

        printDebug("Batch import completed for task: \(task.id) - success: \(successCount), failed: \(failedItems.count)")
        return ImportResultSummary(
            success: successCount,
            failure: failedItems.count,
            failedItems: failedItems,
            stoppedForSpace: stoppedForSpace,
            notAttemptedCount: totalGroups - processedGroups
        )
    }
    
    /// Performs streaming import for MediaSelectionResults with sequential processing.
    ///
    /// Stops before an item that won't fit, and after an item whose load or
    /// write ran out of space, so nothing more is downloaded onto a full disk.
    private func performStreamingImport(
        task: ImportTask,
        results: [MediaSelectionResult],
        fileAccess: FileAccess,
        plannedSizes: [Int64?]? = nil
    ) async throws -> (summary: ImportResultSummary, assetIdentifiers: [String]) {
        printDebug("Performing streaming import for task: \(task.id) with \(results.count) results")
        let startTime = Date()
        var processedCount = 0
        var successCount = 0
        var failedItems: [ImportItemFailure] = []
        var collectedAssetIdentifiers: [String] = []
        var attemptedCount = 0
        var stoppedForSpace = false
        
        for (index, result) in results.enumerated() {
            // Cancelling stops the loop but keeps what already landed: the caller
            // sees fewer processed items than requested and finalizes as cancelled
            // with these asset identifiers, which the import history needs to offer
            // deleting exactly the originals that made it in.
            if Task.isCancelled { break }

            guard hasRoom(forItemSizes: [plannedSize(at: index, in: plannedSizes)]) else {
                printDebug("Not enough space for item \(index + 1) - stopping import")
                stoppedForSpace = true
                break
            }
            attemptedCount += 1
            
            printDebug("📄 Processing item \(index + 1)/\(results.count)")
            
            var loaded: LoadedMediaItem?
            do {
                let item = try await mediaLoader.loadSingleMedia(from: result)
                loaded = item
                
                try await importSingleItem(
                    mediaGroup: item.media,
                    metadata: item.metadata,
                    fileAccess: fileAccess,
                    task: task,
                    groupIndex: index,
                    totalGroups: results.count,
                    startTime: startTime,
                    processedGroups: processedCount
                )
                
                if task.source.canDeleteTempFilesAfterImport {
                    deleteTempFiles(for: item.media)
                }
                
                if let assetId = item.assetIdentifier {
                    collectedAssetIdentifiers.append(assetId)
                }
                
                successCount += 1
                processedCount += 1
                printDebug("✅ Successfully imported item \(index + 1)/\(results.count)")
                
            } catch is CancellationError {
                break
            } catch {
                failedItems.append(ImportItemFailure(id: loaded?.assetIdentifier ?? "\(index)", error: error))
                printDebug("❌ Error processing item \(index + 1): \(error)")
                if ImportSkipReason.isOutOfSpace(error) {
                    if let loaded, task.source.canDeleteTempFilesAfterImport {
                        deleteTempFiles(for: loaded.media)
                    }
                    printDebug("Item \(index + 1) ran out of space - stopping import")
                    stoppedForSpace = true
                    break
                }
            }
        }
        
        printDebug("📈 Streaming import complete - Processed: \(processedCount)/\(results.count) (Success: \(successCount), Failed: \(failedItems.count), AssetIDs: \(collectedAssetIdentifiers.count))")
        let summary = ImportResultSummary(
            success: successCount,
            failure: failedItems.count,
            failedItems: failedItems,
            stoppedForSpace: stoppedForSpace,
            notAttemptedCount: stoppedForSpace ? results.count - attemptedCount : 0
        )
        return (summary, collectedAssetIdentifiers)
    }

    // MARK: - Free Space

    private func plannedSize(at index: Int, in plannedSizes: [Int64?]?) -> Int64? {
        guard let plannedSizes, plannedSizes.indices.contains(index) else { return nil }
        return plannedSizes[index]
    }

    /// Whether writing items of these sizes leaves the reserve untouched.
    /// Unknown sizes count as zero, so only the reserve is checked for them.
    private func hasRoom(forItemSizes sizes: [Int64?]) -> Bool {
        guard let free = freeSpace.availableBytesForImport() else { return true }
        let needed = sizes.compactMap { $0 }.reduce(Int64(0)) { $0 + ImportSpaceBudget.storedBytes(forItemOfSize: $1) }
        return free >= ImportSpaceBudget.reserveBytes + needed
    }
    
    // MARK: - Media Processing
    
    /// Helper to process a single item (load -> save -> progress)
    private func importSingleItem(
        mediaGroup: [CleartextMedia],
        metadata: EncryptedFileMetadata? = nil,
        fileAccess: FileAccess,
        task: ImportTask,
        groupIndex: Int,
        totalGroups: Int,
        startTime: Date,
        processedGroups: Int
    ) async throws {
        try await MediaImportTestHooks.beforeSavingItem(at: groupIndex)
        let mediaId = mediaGroup.first?.id ?? "unknown"
        let interactableMedia = try InteractableMedia(underlyingMedia: mediaGroup)
        
        try await saveMedia(
            interactableMedia,
            metadata: metadata,
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
        
        var metadata: EncryptedFileMetadata?
        if let firstMedia = mediaGroup.first, let url = firstMedia.url {
            let extractor = MediaMetadataExtractor()
            metadata = await extractor.extractMetadata(from: url, mediaType: firstMedia.mediaType)
            if let originalFilename = firstMedia.originalFilename {
                metadata?.originalFilename = originalFilename
            }
        }
        
        try await importSingleItem(
            mediaGroup: mediaGroup,
            metadata: metadata,
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
        metadata: EncryptedFileMetadata? = nil,
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
            try await saveOperation(fileAccess, interactableMedia, metadata) { fileProgress in
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
                    // Delay non-critical work to let biometric authentication complete first
                    try? await Task.sleep(nanoseconds: 500_000_000)
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
