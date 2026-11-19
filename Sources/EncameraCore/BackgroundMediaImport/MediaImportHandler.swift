//
//  MediaImportHandler.swift
//  EncameraCore
//
//  Created by Alexander Freas on 10.12.25.
//

import Foundation
import BackgroundTasks
import Combine

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

/// Loads one selected item into temporary cleartext files, reporting 0...1
/// while it does. Progress may arrive on any queue. Not main-actor isolated,
/// so a nonisolated loader does its work off the main thread.
public protocol ImportMediaLoading: Sendable {
    func loadSingleMedia(from result: MediaSelectionResult, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedMediaItem
}

extension MediaLoaderService: ImportMediaLoading {}

/// Writes one media group into the album. Injected so tests can fail a save.
/// Called off the main thread; `progress` may be called from any queue.
public typealias ImportSaveOperation = @Sendable (
    _ fileAccess: FileAccess,
    _ media: InteractableMedia<CleartextMedia>,
    _ metadata: EncryptedFileMetadata?,
    _ progress: @escaping @Sendable (Double) -> Void
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
    
    private var cancellables = Set<AnyCancellable>()
    /// Imports between the start of their run and its end, including one that
    /// was cancelled and is still finishing its current item. Temp files are
    /// only cleaned up when this is zero.
    private var runningImportCount = 0
    private let mediaLoader: ImportMediaLoading
    private let saveOperation: ImportSaveOperation
    private var freeSpace: DeviceFreeSpaceProviding
    /// Called each time an import's progress is about to hop to the main
    /// actor, from the thread that reported it. Lets tests count the hops.
    var onProgressHopToMain: (@Sendable () -> Void)?
    
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
        self.saveOperation = saveOperation ?? { @Sendable fileAccess, media, metadata, progress in
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

        let backgroundTask = beginBackgroundTask(for: task.id)
        runningImportCount += 1
        defer {
            runningImportCount -= 1
            endBackgroundTask(backgroundTask)
            cleanupTempFilesIfSafe()
        }
        taskManager.resetTimeEstimationState()

        let isPreloaded: Bool
        if case .preloaded = mediaSource { isPreloaded = true } else { isPreloaded = false }
        let totalItems = mediaSource.count
        let startTime = Date()
        let sink = ImportProgressSink(aggregator: ImportProgressAggregator(totalItems: totalItems),
                                      onMainHop: onProgressHopToMain) { [weak self] item, mediaId, aggregator in
            self?.updateImportProgress(task: task, groupIndex: item, totalGroups: totalItems,
                                       startTime: startTime, mediaId: mediaId, progress: aggregator)
        }
        let taskManager = taskManager
        let pipeline = ImportPipeline(
            mediaLoader: mediaLoader,
            saveOperation: saveOperation,
            freeSpace: freeSpace,
            isTaskActive: { taskManager.hasTask(task.id) },
            canDeleteTempFiles: task.source.canDeleteTempFilesAfterImport,
            testHooks: MediaImportTestHooks.Snapshot(),
            sink: sink
        )

        // Inherits this actor, but only to start: the pipeline's methods are
        // nonisolated, so the per-item work runs off the main thread.
        let importTask = Task { () -> ImportRunOutcome in
            let fileAccess = await InteractableMediaFileAccess(for: album, albumManager: albumManager)

            switch mediaSource {
            case .preloaded(let media):
                let summary = try await pipeline.runBatch(task: task, media: media, fileAccess: fileAccess, plannedSizes: plannedSizes)
                return ImportRunOutcome(summary: summary, assetIdentifiers: task.assetIdentifiers,
                                        mediaIdsByAssetId: nil, wasCancelled: false)

            case .streaming(let results):
                let outcome = await pipeline.runStreaming(task: task, results: results, fileAccess: fileAccess, plannedSizes: plannedSizes)
                let summary = outcome.summary
                return ImportRunOutcome(summary: summary, assetIdentifiers: outcome.assetIdentifiers,
                                        mediaIdsByAssetId: outcome.mediaIdsByAssetId,
                                        wasCancelled: summary.success + summary.failure + summary.notAttemptedCount < results.count)
            }
        }
        // Registered right after the Task exists, with no suspension since
        // `addTask`, so a Stop always reaches this import's own Task.
        taskManager.registerCancellationHandler(for: task.id) { [weak self] in
            self?.printDebug("Cancel handler for \(task.id)")
            importTask.cancel()
        }

        let outcome: ImportRunOutcome
        do {
            outcome = try await importTask.value
            sink.close()
        } catch is CancellationError {
            // Only a batch run throws on cancel; a streaming run returns its
            // partial outcome instead.
            sink.close()
            let partialIdentifiers = task.assetIdentifiers
            printDebug("Import was cancelled with \(partialIdentifiers.count) asset identifiers")
            taskManager.finalizeTaskCancelled(taskId: task.id, assetIdentifiers: partialIdentifiers)
            return ImportResultSummary(success: 0, failure: 0)
        } catch {
            sink.close()
            taskManager.finalizeTaskFailed(taskId: task.id, error: error)
            throw error
        }

        let summary = outcome.summary
        let successCount = summary.success
        let failureCount = summary.failure
        let assetIdentifiers = outcome.assetIdentifiers
        let mediaIds = outcome.mediaIdsByAssetId
        if outcome.wasCancelled {
            printDebug("Streaming import was cancelled with \(assetIdentifiers.count) partial imports")
            taskManager.finalizeTaskCancelled(taskId: task.id, assetIdentifiers: assetIdentifiers,
                                              mediaIdsByAssetId: mediaIds)
            recordHistory(for: task, album: album, state: .cancelled, importedCount: successCount,
                          requestedCount: totalItems, assetIdentifiers: assetIdentifiers,
                          mediaIdsByAssetId: mediaIds)
        } else if summary.stoppedForSpace {
            printDebug("Import stopped for space after \(successCount) imports, \(summary.notAttemptedCount) not attempted")
            if successCount > 0 {
                let identifiers = isPreloaded ? [] : assetIdentifiers
                taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: successCount, assetIdentifiers: identifiers,
                                                  mediaIdsByAssetId: mediaIds)
                recordHistory(for: task, album: album, state: .completed, importedCount: successCount,
                              requestedCount: totalItems, assetIdentifiers: identifiers,
                              mediaIdsByAssetId: mediaIds)
            } else {
                taskManager.finalizeTaskFailed(taskId: task.id, error: BackgroundImportError.outOfSpace)
            }
        } else if successCount == 0 && failureCount > 0 {
            printDebug("Import had \(failureCount) failures and no successes - finalizing failed")
            taskManager.finalizeTaskFailed(taskId: task.id, error: BackgroundImportError.allImportsFailed(failureCount: failureCount))
        } else {
            let completedItems = (isPreloaded && successCount > 0) ? successCount : totalItems
            taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: completedItems, assetIdentifiers: assetIdentifiers,
                                              mediaIdsByAssetId: mediaIds)
            // Preloaded identifiers are the caller's, not per item, so once anything
            // failed there is no telling which original did not make it in.
            let deletableIdentifiers = isPreloaded && failureCount > 0 ? [] : assetIdentifiers
            recordHistory(for: task, album: album, state: .completed, importedCount: successCount,
                          requestedCount: totalItems, assetIdentifiers: deletableIdentifiers,
                          mediaIdsByAssetId: mediaIds)
        }

        return summary
    }

    /// Adds the finished batch to the album's import history. An import that
    /// brought nothing in leaves no record: there is nothing to delete.
    private func recordHistory(for task: ImportTask,
                               album: Album,
                               state: ImportHistoryRecord.State,
                               importedCount: Int,
                               requestedCount: Int,
                               assetIdentifiers: [String],
                               mediaIdsByAssetId: [String: String]?) {
        guard importedCount > 0 else { return }
        let record = ImportHistoryRecord(id: task.userBatchId ?? task.id,
                                         createdAt: task.createdAt,
                                         source: task.source,
                                         importedCount: importedCount,
                                         requestedCount: requestedCount,
                                         assetIdentifiers: assetIdentifiers,
                                         mediaIdsByAssetId: mediaIdsByAssetId,
                                         state: state)
        do {
            try AlbumImportHistory(album: album).append(record)
        } catch {
            printDebug("Could not record import history for task \(task.id): \(error)")
        }
    }

    /// What one import run returns to the coordinator to finalize.
    private struct ImportRunOutcome: Sendable {
        let summary: ImportResultSummary
        let assetIdentifiers: [String]
        /// Which album item each original became; `nil` for preloaded media,
        /// whose asset ids are the caller's and not paired with items.
        let mediaIdsByAssetId: [String: String]?
        let wasCancelled: Bool
    }

    /// Share of a picked item's progress spent loading it; see `ImportPipeline`.
    static let streamingLoadShare = ImportPipeline.streamingLoadShare

    /// Publishes the import's current progress. Runs on main, through the
    /// pipeline's progress sink.
    private func updateImportProgress(
        task: ImportTask,
        groupIndex: Int,
        totalGroups: Int,
        startTime: Date,
        mediaId: String?,
        progress aggregator: ImportProgressAggregator
    ) {
        let overallProgress = aggregator.fraction
        let estimatedTimeRemaining = taskManager.calculateEstimatedTime(startTime: startTime, progress: overallProgress)
        
        let progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: groupIndex,
            totalFiles: totalGroups,
            currentFileProgress: aggregator.fraction(ofItem: groupIndex),
            overallProgress: overallProgress,
            currentFileName: mediaId,
            state: .running,
            estimatedTimeRemaining: estimatedTimeRemaining
        )
        
        taskManager.updateTaskProgress(taskId: task.id, progress: progress)
    }
    
    private func cleanupTempFilesIfSafe() {
        printDebug("cleanupTempFilesIfSafe() called, running imports: \(runningImportCount)")
        
        printDebug("Current tasks count: \(taskManager.currentTasks.count)")
        for (index, task) in taskManager.currentTasks.enumerated() {
            if let importTask = task as? ImportTask {
                printDebug("Task \(index): id=\(importTask.id), state=\(importTask.progress.state), source=\(importTask.source.rawValue)")
            }
        }
        
        if runningImportCount == 0 {
            printDebug("No running imports - cleaning up temporary files")
            TempFileAccess.cleanupTemporaryFiles()
            printDebug("TempFileAccess.cleanupTemporaryFiles() completed")
        } else {
            printDebug("Running imports (\(runningImportCount)) - keeping temp files")
        }
    }
    
    // MARK: - Background Task Management
    
    /// Begins this import's own background task. The expiration handler and the
    /// run's end share one `ImportBackgroundTask`, so it is ended exactly once.
    private func beginBackgroundTask(for taskId: String) -> ImportBackgroundTask {
        let backgroundTask = ImportBackgroundTask()
        backgroundTask.id = BackgroundExecution.begin(name: "MediaImport") { [weak self] in
            self?.printDebug("UIBackgroundTask for import \(taskId) expired - time limit reached")
            self?.endBackgroundTask(backgroundTask)
        }
        if backgroundTask.id == .invalid {
            printDebug("Failed to start UIBackgroundTask for import \(taskId) - got invalid identifier")
        } else {
            printDebug("UIBackgroundTask \(backgroundTask.id.rawValue) started for import \(taskId)")
        }
        return backgroundTask
    }

    private func endBackgroundTask(_ backgroundTask: ImportBackgroundTask) {
        guard backgroundTask.id != .invalid else { return }
        printDebug("Ending UIBackgroundTask with identifier: \(backgroundTask.id.rawValue)")
        BackgroundExecution.end(backgroundTask.id)
        backgroundTask.id = .invalid
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

/// One import's background-task id, shared by its expiration handler and the
/// end of its run.
@MainActor
private final class ImportBackgroundTask {
    var id: BackgroundTaskID = .invalid
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
