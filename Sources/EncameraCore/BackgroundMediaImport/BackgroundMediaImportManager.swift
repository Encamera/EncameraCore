import Foundation
import BackgroundTasks
import Combine
import UIKit


@MainActor
public class BackgroundMediaImportManager: ObservableObject, DebugPrintable {
    
    public static let shared = BackgroundMediaImportManager()
    
    // MARK: - Published Properties
    @Published public var currentTasks: [ImportTask] = []
    @Published public var isImporting: Bool = false
    @Published public var overallProgress: Double = 0.0
    
    // MARK: - Private Properties
    private var albumManager: AlbumManaging?
    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    private var taskQueue = DispatchQueue(label: "media.import.queue", qos: .userInitiated)
    private var currentImportTask: Task<Void, Error>?
    private let mediaLoader = MediaLoaderService()
    
    // Time estimation smoothing
    private var smoothedTimeEstimate: TimeInterval?
    private var lastTimeEstimateUpdate: Date?
    private var progressHistory: [(date: Date, progress: Double)] = []
    private let timeEstimateUpdateInterval: TimeInterval = 2.0 // Update estimate every 2 seconds
    private let smoothingFactor: Double = 0.3 // Exponential smoothing factor (0.0 = no smoothing, 1.0 = no history)
    
    // Progress tracking
    private var progressSubject = PassthroughSubject<ImportProgressUpdate, Never>()
    public var progressPublisher: AnyPublisher<ImportProgressUpdate, Never> {
        progressSubject.eraseToAnyPublisher()
    }
    
    public init() {
        setupNotificationObservers()
    }

    // MARK: - Public API

    public func configure(albumManager: AlbumManaging) {
        printDebug("Configuring BackgroundMediaImportManager with albumManager")
        self.albumManager = albumManager
    }
    
    /// High-level API: Start import directly from MediaSelectionResults (PHAssets or PHPickerResults)
    /// This handles the complete flow: preparation, media loading, and import
    public func startImport(results: [MediaSelectionResult], albumId: String, source: ImportSource) async throws {
        printDebug("Starting import from \(results.count) MediaSelectionResults to album: \(albumId)")
        
        // Generate a unique batch ID for this user selection
        let userBatchId = UUID().uuidString
        
        // Start preparation phase IMMEDIATELY - shows progress view right away
        let preparationTaskId = startPreparation(
            totalFiles: results.count,
            albumId: albumId,
            source: source
        )
        
        // Streaming state for batch processing
        let streamingBatchSize = 5
        var allMedia: [CleartextMedia] = []
        var assetIdentifiers: [String] = []
        var firstBatchMedia: [CleartextMedia] = []
        var firstBatchAssetIds: [String] = []
        var hasStartedFirstImport = false
        var successfulLoads = 0
        
        // Process each result with progress updates
        for (index, result) in results.enumerated() {
            printDebug("📄 Processing result \(index + 1)/\(results.count)")
            
            do {
                let (media, assetId) = try await loadMediaFromResult(result)
                
                allMedia.append(contentsOf: media)
                successfulLoads += 1
                
                if let assetId = assetId {
                    assetIdentifiers.append(assetId)
                }
                
                // Update preparation progress
                updatePreparation(
                    taskId: preparationTaskId,
                    preparedFiles: successfulLoads,
                    totalFiles: results.count
                )
                
                // Start first batch import early for large imports
                if !hasStartedFirstImport &&
                   successfulLoads >= streamingBatchSize &&
                   results.count > streamingBatchSize {
                    hasStartedFirstImport = true
                    firstBatchMedia = allMedia
                    firstBatchAssetIds = assetIdentifiers
                    
                    printDebug("🚀 Starting early import with first \(successfulLoads) files")
                    Task {
                        do {
                            try await startImport(
                                media: firstBatchMedia,
                                albumId: albumId,
                                source: source,
                                assetIdentifiers: firstBatchAssetIds,
                                userBatchId: userBatchId
                            )
                        } catch {
                            printDebug("❌ Error starting first batch import: \(error)")
                        }
                    }
                }
                
            } catch {
                printDebug("❌ Error loading media from result: \(error)")
            }
        }
        
        printDebug("📈 Summary - Successful: \(successfulLoads), Total media: \(allMedia.count)")
        
        // All files loaded - complete the preparation task
        completePreparation(taskId: preparationTaskId)
        
        // Start import for remaining files or all files if no streaming occurred
        if hasStartedFirstImport {
            // Import remaining files not in first batch
            let remainingMedia = Array(allMedia.dropFirst(firstBatchMedia.count))
            let remainingAssetIds = Array(assetIdentifiers.dropFirst(firstBatchAssetIds.count))
            
            guard !remainingMedia.isEmpty else { return }
            
            try await startImport(
                media: remainingMedia,
                albumId: albumId,
                source: source,
                assetIdentifiers: remainingAssetIds,
                userBatchId: userBatchId
            )
        } else {
            // No streaming - start full import
            try await startImport(
                media: allMedia,
                albumId: albumId,
                source: source,
                assetIdentifiers: assetIdentifiers,
                userBatchId: userBatchId
            )
        }
    }
    
    /// Helper to load media from a single MediaSelectionResult using MediaLoaderService
    private func loadMediaFromResult(_ result: MediaSelectionResult) async throws -> (media: [CleartextMedia], assetId: String?) {
        switch result {
        case .phAsset(let asset):
            let batch = try await mediaLoader.loadMedia(from: [result])
            return (batch.media, asset.localIdentifier)
        case .phPickerResult(let pickerResult):
            let batch = try await mediaLoader.loadMedia(from: [result])
            return (batch.media, pickerResult.assetIdentifier)
        }
    }
    
    /// Starts the preparation phase before files are ready for import.
    /// This shows the progress view immediately with "Preparing X files..." message.
    /// Returns a task ID that should be used when calling `startImport` to continue the same task.
    internal func startPreparation(totalFiles: Int, albumId: String, source: ImportSource) -> String {
        printDebug("Starting preparation phase for \(totalFiles) files to album: \(albumId)")
        
        // Create a task with no media yet - it will be populated later
        let taskId = UUID().uuidString
        let task = ImportTask(id: taskId, media: [], albumId: albumId, source: source, assetIdentifiers: [])
        
        // Set the task to preparing state
        var mutableTask = task
        mutableTask.progress.state = .preparing(totalFiles: totalFiles, preparedFiles: 0)
        
        currentTasks.append(mutableTask)
        isImporting = true
        
        printDebug("Created preparation task with ID: \(taskId)")
        return taskId
    }
    
    /// Updates the preparation progress as files are being loaded from the photo library
    internal func updatePreparation(taskId: String, preparedFiles: Int, totalFiles: Int) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Failed to find task to update preparation: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = .preparing(totalFiles: totalFiles, preparedFiles: preparedFiles)
        publishProgress(for: currentTasks[taskIndex])
    }
    
    /// Cancels a preparation task (if user cancels before files are ready)
    internal func cancelPreparation(taskId: String) {
        printDebug("Cancelling preparation task: \(taskId)")
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Failed to find preparation task to cancel: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = .cancelled
        publishProgress(for: currentTasks[taskIndex])
        
        // Remove from active tasks after a delay to show cancelled state
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.currentTasks.removeAll { $0.id == taskId }
            self.updateOverallProgress()
            self.updateIsImporting()
        }
    }
    
    /// Completes a preparation task by removing it from the task list.
    /// Call this when all files have been loaded and are ready for import.
    internal func completePreparation(taskId: String) {
        printDebug("Completing preparation task: \(taskId)")
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Failed to find preparation task to complete: \(taskId)")
            return
        }
        
        // Simply remove it - the actual imports have already been queued
        currentTasks.remove(at: taskIndex)
        updateOverallProgress()
        updateIsImporting()
    }
    
    /// Transitions a preparation task to actual import with the loaded media
    private func startImportFromPreparation(taskId: String, media: [CleartextMedia], assetIdentifiers: [String] = [], userBatchId: String? = nil) async throws {
        printDebug("Starting import from preparation task: \(taskId) with \(media.count) media items")
        
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Failed to find preparation task: \(taskId), starting fresh import")
            // Fall back to creating a new task if preparation task not found
            throw BackgroundImportError.configurationError
        }
        
        let albumId = currentTasks[taskIndex].albumId
        let source = currentTasks[taskIndex].source
        
        // Remove the preparation task and create a real import task
        currentTasks.remove(at: taskIndex)
        
        // Now start the actual import
        try await startImport(media: media, albumId: albumId, source: source, assetIdentifiers: assetIdentifiers, userBatchId: userBatchId)
    }

    public func startImport(media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = [], userBatchId: String? = nil) async throws {
        printDebug("Starting import for \(media.count) media items to album: \(albumId) from source: \(source.rawValue) with \(assetIdentifiers.count) asset identifiers")
        // Reset time estimation for new import
        resetTimeEstimationState()
        
        // Log details about each media item
        for (index, mediaItem) in media.prefix(5).enumerated() { // Log first 5 items
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
        
        let task = ImportTask(media: media, albumId: albumId, source: source, assetIdentifiers: assetIdentifiers, userBatchId: userBatchId)
        currentTasks.append(task)
        
        // Set isImporting immediately when task is created, not in executeImportTask
        // This ensures the progress view can appear before execution begins
        isImporting = true
        
        printDebug("Created import task with ID: \(task.id)")
        printDebug("Total current tasks: \(currentTasks.count)")
        
        try await executeImportTask(task)
    }
    
    public func pauseImport(taskId: String) {
        printDebug("Pausing import task: \(taskId)")
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else { 
            printDebug("Failed to find task to pause: \(taskId)")
            return 
        }
        
        currentTasks[taskIndex].progress.state = .paused
        currentImportTask?.cancel()
        
        publishProgress(for: currentTasks[taskIndex])
    }
    
    public func resumeImport(taskId: String) async throws {
        printDebug("Resuming import task: \(taskId)")
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }),
              currentTasks[taskIndex].progress.state == .paused else {
            printDebug("Failed to find paused task to resume: \(taskId)")
            return
        }
        
        try await executeImportTask(currentTasks[taskIndex])
    }
    
    public func cancelImport(taskId: String) {
        printDebug("Cancelling import task: \(taskId)")
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Failed to find task to cancel: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = .cancelled
        currentImportTask?.cancel()
        
        publishProgress(for: currentTasks[taskIndex])
        
        // Remove from active tasks after a delay to show cancelled state
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.printDebug("Removing cancelled task: \(taskId)")
            self.currentTasks.removeAll { $0.id == taskId }
            self.updateOverallProgress()
        }
    }
    
    public func removeCompletedTasks() {
        let tasksToRemove = currentTasks.filter { task in
            switch task.progress.state {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
        
        printDebug("Removing \(tasksToRemove.count) completed/cancelled/failed tasks")
        currentTasks.removeAll { task in
            switch task.progress.state {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
        updateOverallProgress()
    }
    
    /// Removes a specific task by ID without changing its state.
    /// Use this for removing completed tasks from import history.
    public func removeTask(taskId: String) {
        printDebug("Removing task: \(taskId)")
        currentTasks.removeAll { $0.id == taskId }
        updateOverallProgress()
        updateIsImporting()
    }
    
    public func clearAllTasks() {
        printDebug("Clearing all tasks and resetting state")
        
        // Cancel any running import tasks
        currentImportTask?.cancel()
        currentImportTask = nil
        
        // End any active background task
        endBackgroundTask()
        
        // Clear all tasks regardless of state
        let taskCount = currentTasks.count
        currentTasks.removeAll()
        printDebug("Cleared \(taskCount) tasks")
        
        // Reset all progress tracking
        isImporting = false
        overallProgress = 0.0
        updateOverallProgress() // Ensure progress is properly recalculated and published
        
        // Reset time estimation smoothing state
        resetTimeEstimationState()
        
        // Clean up temp files since no imports are active
        cleanupTempFilesIfSafe()
        
        printDebug("All tasks cleared and state reset")
    }
    
    // MARK: - Private Implementation
    
    private func executeImportTask(_ task: ImportTask) async throws {
        printDebug("Executing import task: \(task.id) with \(task.media.count) media items")
        albumManager?.loadAlbumsFromFilesystem()
        guard let albumManager = albumManager,
              let album = albumManager.albums.first(where: { $0.id == task.albumId }) else {
            printDebug("Failed to execute import task - missing configuration or album", albumManager?.albums)
            throw BackgroundImportError.configurationError
        }
        
        let taskIndex = currentTasks.firstIndex(where: { $0.id == task.id })!
        currentTasks[taskIndex].progress.state = .running
        isImporting = true
        
        printDebug("Starting background task for import: \(task.id)")
        startBackgroundTask()
        
        currentImportTask = Task {
            do {
                let fileAccess = await InteractableMediaDiskAccess(for: album, albumManager: albumManager)
                try await performImport(task: task, fileAccess: fileAccess)
                
                await MainActor.run {
                    self.printDebug("Import task completed successfully: \(task.id)")
                    if let index = self.currentTasks.firstIndex(where: { $0.id == task.id }) {
                        // Use uniqueMediaCount to correctly count live photos as single items
                        let totalItems = task.uniqueMediaCount
                        self.currentTasks[index].progress = ImportProgressUpdate(
                            taskId: task.id,
                            currentFileIndex: totalItems - 1,
                            totalFiles: totalItems,
                            currentFileProgress: 1.0,
                            overallProgress: 1.0,
                            currentFileName: nil,
                            state: .completed,
                            estimatedTimeRemaining: 0
                        )
                        self.publishProgress(for: self.currentTasks[index])
                    }
                    self.updateIsImporting()
                    self.endBackgroundTask()
                    
                    // Clean up temp files only if no other photo imports are running
                    self.cleanupTempFilesIfSafe()
                }
            } catch {
                await MainActor.run {
                    self.printDebug("Import task failed with error: \(error.localizedDescription) for task: \(task.id)")
                    if let index = self.currentTasks.firstIndex(where: { $0.id == task.id }) {
                        self.currentTasks[index].progress.state = .failed(error)
                        self.publishProgress(for: self.currentTasks[index])
                    }
                    self.updateOverallProgress()
                    self.updateIsImporting()
                    self.endBackgroundTask()
                    
                    // Clean up temp files only if no other photo imports are running
                    self.cleanupTempFilesIfSafe()
                }
                throw error
            }
        }
        
        try await currentImportTask?.value
    }
    
    private func performImport(task: ImportTask, fileAccess: FileAccess) async throws {
        printDebug("Performing import for task: \(task.id)")
        let startTime = Date()
        var processedGroups = 0
        
        // Group media by ID so live photo components (image + video) are processed together
        let mediaGroups = groupMediaById(task.media)
        let totalGroups = mediaGroups.count
        printDebug("Grouped \(task.media.count) media items into \(totalGroups) groups (live photos count as 1)")
        
        // Process groups concurrently in batches to avoid overwhelming the system
        let batchSize = 3
        let batches = mediaGroups.chunked(into: batchSize)
        printDebug("Processing \(batches.count) batches of size \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            printDebug("Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) media groups")
            
            // Process batch concurrently
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
        
        printDebug("Import completed for task: \(task.id)")
    }
    
    /// Processes a group of CleartextMedia items as a single InteractableMedia.
    /// For live photos, this receives both the image and video components together.
    /// For regular photos/videos, this receives a single-element array.
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
    
    /// Updates the import progress for a task.
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
        let estimatedTimeRemaining = calculateEstimatedTime(startTime: startTime, progress: overallProgress)
        
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == task.id }) else { return }
        
        currentTasks[taskIndex].progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: groupIndex,
            totalFiles: totalGroups,
            currentFileProgress: fileProgress,
            overallProgress: overallProgress,
            currentFileName: mediaId,
            state: .running,
            estimatedTimeRemaining: estimatedTimeRemaining
        )
        publishProgress(for: currentTasks[taskIndex])
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
    
    private func publishProgress(for task: ImportTask) {

        if floor(task.progress.overallProgress * 100).truncatingRemainder(dividingBy: 10) == 0 {
            printDebug("Publishing progress for task \(task.id): \(task.progress.overallProgress * 100)% complete, \(task.progress.state), \(task.progress.state)")
        }
        self.updateOverallProgress()
        progressSubject.send(task.progress)
    }
    
    private func updateOverallProgress() {
        let previousProgress = overallProgress
        
        let activeTasks = currentTasks.filter { task in
            switch task.progress.state {
            case .running, .paused:
                return true
            default:
                return false
            }
        }
        
        if activeTasks.isEmpty {
            overallProgress = 0.0
        } else {
            let totalProgress = activeTasks.reduce(0.0) { $0 + $1.progress.overallProgress }
            overallProgress = totalProgress / Double(activeTasks.count)
        }
        
        if previousProgress != overallProgress {
            printDebug("Overall progress updated: \(previousProgress * 100)% -> \(overallProgress * 100)%, active tasks: \(activeTasks.map({$0.progress.state}))")
        }
    }
    
    private func updateIsImporting() {
        let wasImporting = isImporting
        isImporting = currentTasks.contains { task in
            task.progress.state == .running
        }
        if wasImporting != isImporting {
            printDebug("Import status changed: \(wasImporting) -> \(isImporting)")
        }
    }
    
    private func calculateEstimatedTime(startTime: Date, progress: Double) -> TimeInterval? {
        guard progress > 0.05 else { 
            // Reset smoothing state for new imports
            smoothedTimeEstimate = nil
            lastTimeEstimateUpdate = nil
            progressHistory.removeAll()
            return nil 
        }
        
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        
        // Add current progress to history
        progressHistory.append((date: now, progress: progress))
        
        // Clean up old progress history (keep last 30 seconds of data)
        let cutoffTime = now.addingTimeInterval(-30)
        progressHistory.removeAll { $0.date < cutoffTime }
        
        // Check if enough time has passed since last estimate update (debouncing)
        if let lastUpdate = lastTimeEstimateUpdate,
           now.timeIntervalSince(lastUpdate) < timeEstimateUpdateInterval,
           smoothedTimeEstimate != nil {
            // Return cached estimate if we're within debounce interval
            return smoothedTimeEstimate
        }
        
        // Calculate new estimate using progress history for more stability
        let newEstimate = calculateSmoothedEstimate(startTime: startTime, progress: progress, currentTime: now)
        
        // Apply exponential smoothing if we have a previous estimate
        if let previousEstimate = smoothedTimeEstimate {
            smoothedTimeEstimate = smoothingFactor * newEstimate + (1 - smoothingFactor) * previousEstimate
        } else {
            smoothedTimeEstimate = newEstimate
        }
        
        lastTimeEstimateUpdate = now
        
        return smoothedTimeEstimate.map { max(0, $0) }
    }
    
    private func calculateSmoothedEstimate(startTime: Date, progress: Double, currentTime: Date) -> TimeInterval {
        let elapsed = currentTime.timeIntervalSince(startTime)
        
        // If we have enough progress history, use rate-based calculation for more stability
        if progressHistory.count >= 3 {
            // Calculate average progress rate over recent history
            let recentHistory = Array(progressHistory.suffix(min(10, progressHistory.count)))
            
            if recentHistory.count >= 2 {
                let timeSpan = recentHistory.last!.date.timeIntervalSince(recentHistory.first!.date)
                let progressSpan = recentHistory.last!.progress - recentHistory.first!.progress
                
                if timeSpan > 0 && progressSpan > 0 {
                    let progressRate = progressSpan / timeSpan
                    let remainingProgress = 1.0 - progress
                    let rateBasedEstimate = remainingProgress / progressRate
                    
                    // Blend rate-based estimate with simple calculation for stability
                    let simpleEstimate = elapsed / progress - elapsed
                    let blendFactor = min(1.0, timeSpan / 10.0) // Give more weight to rate-based as we have more data
                    
                    return blendFactor * rateBasedEstimate + (1 - blendFactor) * simpleEstimate
                }
            }
        }
        
        // Fallback to simple calculation
        let totalEstimate = elapsed / progress
        return totalEstimate - elapsed
    }
    
    private func resetTimeEstimationState() {
        printDebug("Resetting time estimation smoothing state")
        smoothedTimeEstimate = nil
        lastTimeEstimateUpdate = nil
        progressHistory.removeAll()
    }
    
    /// Groups CleartextMedia items by their ID so that live photo components (image + video) are processed together.
    /// This ensures live photos are counted as single items rather than counting their components separately.
    private func groupMediaById(_ media: [CleartextMedia]) -> [[CleartextMedia]] {
        var groups: [String: [CleartextMedia]] = [:]
        for item in media {
            groups[item.id, default: []].append(item)
        }
        // Preserve insertion order by iterating through original media
        var seen = Set<String>()
        return media.compactMap { item -> [CleartextMedia]? in
            guard !seen.contains(item.id) else { return nil }
            seen.insert(item.id)
            return groups[item.id]
        }
    }
    
    private func cleanupTempFilesIfSafe() {
        printDebug("cleanupTempFilesIfSafe() called")
        
        // Check if there are any active photo imports or preparing tasks (which use temp files)
        let hasActiveOrPreparingImports = currentTasks.contains { task in
            switch task.progress.state {
            case .running:
                return true
            case .preparing:
                // Preparation tasks mean files are still being loaded to temp - don't cleanup
                return true
            default:
                return false
            }
        }
        
        // Log current task states
        printDebug("Current tasks count: \(currentTasks.count)")
        for (index, task) in currentTasks.enumerated() {
            printDebug("Task \(index): id=\(task.id), state=\(task.progress.state), source=\(task.source.rawValue)")
        }
        
        if !hasActiveOrPreparingImports {
            printDebug("No active or preparing photo imports - cleaning up temporary files")
            printDebug("About to call TempFileAccess.cleanupTemporaryFiles()")
            TempFileAccess.cleanupTemporaryFiles()
            printDebug("TempFileAccess.cleanupTemporaryFiles() completed")
        } else {
            printDebug("Active or preparing photo imports detected - keeping temp files")
            let activeCount = currentTasks.filter { 
                if case .running = $0.progress.state { return true }
                return false
            }.count
            let preparingCount = currentTasks.filter {
                if case .preparing = $0.progress.state { return true }
                return false
            }.count
            printDebug("Number of active imports: \(activeCount), preparing: \(preparingCount)")
        }
    }
    
    // MARK: - Background Task Management
    
    /// Must be called during app launch before application finishes launching
    public static func registerBackgroundTasks() {
        print("Registering background task: com.encamera.media-import")
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.encamera.media-import", using: nil) { task in
            print("Background task handler called for: com.encamera.media-import")
            BackgroundMediaImportManager.shared.handleBackgroundImport(task: task as! BGProcessingTask)
        }
    }
    
    private func scheduleBackgroundImport() {
        printDebug("Scheduling background import task")
        let request = BGProcessingTaskRequest(identifier: "com.encamera.media-import")
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            printDebug("Successfully scheduled background import task")
        } catch {
            printDebug("Failed to schedule background import task: \(error.localizedDescription)")
        }
    }
    
    private func handleBackgroundImport(task: BGProcessingTask) {
        printDebug("Handling background import task")
        let hasActiveTasks = !currentTasks.filter { $0.progress.state == .running || $0.progress.state == .paused }.isEmpty
        printDebug("Has active tasks: \(hasActiveTasks), total tasks: \(currentTasks.count)")
        
        if hasActiveTasks {
            // Continue processing in background
            task.expirationHandler = {
                self.printDebug("Background task expiration handler called")
                task.setTaskCompleted(success: false)
            }
            
            Task {
                printDebug("Starting background task execution")
                // Resume or continue any paused/running tasks
                for importTask in currentTasks where importTask.progress.state == .paused {
                    printDebug("Resuming paused task in background: \(importTask.id)")
                    try? await resumeImport(taskId: importTask.id)
                }
                
                printDebug("Background task execution completed")
                task.setTaskCompleted(success: true)
            }
        } else {
            printDebug("No active tasks to process in background")
            task.setTaskCompleted(success: true)
        }
    }
    
    private func startBackgroundTask() {
        printDebug("Starting UIBackgroundTask")
        endBackgroundTask() // End any existing task
        
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
        
        NotificationUtils.didEnterBackgroundPublisher
            .sink { [weak self] _ in
                self?.printDebug("App did enter background - scheduling background import")
                self?.printDebug("Current active tasks count: \(self?.currentTasks.filter { $0.progress.state == .running }.count ?? 0)")
                self?.printDebug("Active background task identifier: \(self?.activeBackgroundTask.rawValue ?? 0)")
                self?.scheduleBackgroundImport()
            }
            .store(in: &cancellables)
        
        NotificationUtils.willEnterForegroundPublisher
            .sink { [weak self] _ in
                self?.printDebug("App will enter foreground - refreshing task states")
                self?.printDebug("Current tasks: \(self?.currentTasks.count ?? 0)")
                // Refresh task states when returning to foreground
                Task { @MainActor in
                    self?.updateOverallProgress()
                }
            }
            .store(in: &cancellables)
        
        // Add observer for when app will resign active
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
