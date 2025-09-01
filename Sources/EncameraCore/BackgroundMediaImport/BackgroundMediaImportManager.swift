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

    public func startImport(media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = []) async throws {
        printDebug("Starting import for \(media.count) media items to album: \(albumId) from source: \(source.rawValue) with \(assetIdentifiers.count) asset identifiers")
        
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
        
        let task = ImportTask(media: media, albumId: albumId, source: source, assetIdentifiers: assetIdentifiers)
        currentTasks.append(task)
        
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
                        self.currentTasks[index].progress = ImportProgressUpdate(
                            taskId: task.id,
                            currentFileIndex: task.media.count - 1,
                            totalFiles: task.media.count,
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
        var processedFiles = 0
        
        // Process files concurrently in batches to avoid overwhelming the system
        let batchSize = 3
        let batches = task.media.chunked(into: batchSize)
        printDebug("Processing \(batches.count) batches of size \(batchSize)")
        
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            printDebug("Processing batch \(batchIndex + 1)/\(batches.count) with \(batch.count) files")
            
            // Process batch concurrently
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (fileIndex, media) in batch.enumerated() {
                    group.addTask {
                        let globalIndex = batchIndex * batchSize + fileIndex
                        try await self.processSingleFile(
                            media: media,
                            fileAccess: fileAccess,
                            task: task,
                            fileIndex: globalIndex,
                            startTime: startTime,
                            processedFiles: processedFiles
                        )
                    }
                }
                
                try await group.waitForAll()
            }
            
            processedFiles += batch.count
            printDebug("Completed batch \(batchIndex + 1)/\(batches.count), total processed: \(processedFiles)")
        }
        
        printDebug("Import completed for task: \(task.id)")
    }
    
    private func processSingleFile(
        media: CleartextMedia,
        fileAccess: FileAccess,
        task: ImportTask,
        fileIndex: Int,
        startTime: Date,
        processedFiles: Int
    ) async throws {
        printDebug("Processing file \(fileIndex + 1)/\(task.media.count): \(media.id)")
        
        // Enhanced logging for temp file tracking
        if case .url(let sourceURL) = media.source {
            printDebug("Source file URL: \(sourceURL.path)")
            printDebug("Source file absolute path: \(sourceURL.absoluteString)")
            
            // Check file existence and attributes
            let fileManager = FileManager.default
            let exists = fileManager.fileExists(atPath: sourceURL.path)
            printDebug("File exists check: \(exists)")
            
            if exists {
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
                    let fileSize = attributes[.size] as? Int64 ?? 0
                    let modificationDate = attributes[.modificationDate] as? Date
                    let creationDate = attributes[.creationDate] as? Date
                    printDebug("File attributes - Size: \(fileSize) bytes, Modified: \(modificationDate?.description ?? "unknown"), Created: \(creationDate?.description ?? "unknown")")
                    
                    // Check if file is in temp directory
                    if sourceURL.path.contains("/tmp/") {
                        printDebug("WARNING: File is in temp directory and may be cleaned up by the system")
                        printDebug("Temp directory path component: \(sourceURL.pathComponents.filter { $0.contains("tmp") }.joined(separator: "/"))")
                    }
                } catch {
                    printDebug("ERROR: Failed to get file attributes: \(error)")
                }
            } else {
                printDebug("WARNING: Source file does not exist at path: \(sourceURL.path)")
                
                // Check parent directory
                let parentDir = sourceURL.deletingLastPathComponent()
                printDebug("Parent directory: \(parentDir.path)")
                printDebug("Parent directory exists: \(fileManager.fileExists(atPath: parentDir.path))")
                
                // List contents of parent directory if it exists
                if fileManager.fileExists(atPath: parentDir.path) {
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: parentDir.path)
                        printDebug("Parent directory contains \(contents.count) items")
                        if contents.count < 20 {
                            printDebug("Directory contents: \(contents)")
                        }
                    } catch {
                        printDebug("ERROR: Failed to list directory contents: \(error)")
                    }
                }
            }
        }
        
        let interactableMedia = try InteractableMedia(underlyingMedia: [media])
        
        // Check file existence right before save
        if case .url(let sourceURL) = media.source {
            printDebug("Pre-save file check for \(sourceURL.lastPathComponent)")
            printDebug("File exists immediately before save: \(FileManager.default.fileExists(atPath: sourceURL.path))")
        }
        
        do {
            var lastProgressCheck: TimeInterval = 0
            
            try await fileAccess.save(media: interactableMedia) { fileProgress in
                Task { @MainActor in
                    let overallProgress = (Double(processedFiles) + fileProgress) / Double(task.media.count)
                    let estimatedTimeRemaining = self.calculateEstimatedTime(
                        startTime: startTime,
                        progress: overallProgress
                    )
                    
                    // Log file existence during save progress
                    let currentTime = Date().timeIntervalSince1970
                    if currentTime - lastProgressCheck > 1.0 { // Check every second
                        lastProgressCheck = currentTime
                        if case .url(let sourceURL) = media.source {
                            let exists = FileManager.default.fileExists(atPath: sourceURL.path)
                            self.printDebug("During save - Progress: \(fileProgress * 100)%, File exists: \(exists)")
                            if !exists {
                                self.printDebug("CRITICAL: File disappeared during save operation!")
                            }
                        }
                    }
                    
                    if let taskIndex = self.currentTasks.firstIndex(where: { $0.id == task.id }) {
                        self.currentTasks[taskIndex].progress = ImportProgressUpdate(
                            taskId: task.id,
                            currentFileIndex: fileIndex,
                            totalFiles: task.media.count,
                            currentFileProgress: fileProgress,
                            overallProgress: overallProgress,
                            currentFileName: media.id,
                            state: .running,
                            estimatedTimeRemaining: estimatedTimeRemaining
                        )
                        self.publishProgress(for: self.currentTasks[taskIndex])
                    }
                }
            }
            
            printDebug("Successfully saved file \(fileIndex + 1)/\(task.media.count): \(media.id)")
        } catch {
            printDebug("Failed to save file \(media.id): \(error)")
            printDebug("Error type: \(type(of: error))")
            printDebug("Full error description: \(error)")
            
            // Enhanced error analysis
            if let nsError = error as NSError? {
                printDebug("NSError domain: \(nsError.domain), code: \(nsError.code)")
                printDebug("NSError userInfo: \(nsError.userInfo)")
                
                if nsError.domain == NSCocoaErrorDomain && nsError.code == 4 {
                    printDebug("File not found error - likely temp files were cleaned up")
                    
                    // Check if file still exists after error
                    if case .url(let sourceURL) = media.source {
                        printDebug("Post-error file check: \(FileManager.default.fileExists(atPath: sourceURL.path))")
                    }
                } else if nsError.domain == "PHPhotosErrorDomain" && nsError.code == -1 {
                    printDebug("Photos framework error - generic error code -1")
                }
            }
            
            // Check if it's an authentication error
            if error.localizedDescription.contains("User interaction required") ||
               error.localizedDescription.contains("Caller is not running foreground") {
                printDebug("Authentication error in background - cannot access protected keychain items")
            }
            
            throw error
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
        guard progress > 0.05 else { return nil } // Wait for meaningful progress
        
        let elapsed = Date().timeIntervalSince(startTime)
        let totalEstimate = elapsed / progress
        let remaining = totalEstimate - elapsed
        
        return max(0, remaining)
    }
    
    private func cleanupTempFilesIfSafe() {
        printDebug("cleanupTempFilesIfSafe() called")
        
        // Check if there are any active photo imports (which use temp files)
        let hasActivePhotoImports = currentTasks.contains { task in
            task.progress.state == .running
        }
        
        // Log current task states
        printDebug("Current tasks count: \(currentTasks.count)")
        for (index, task) in currentTasks.enumerated() {
            printDebug("Task \(index): id=\(task.id), state=\(task.progress.state), source=\(task.source.rawValue)")
        }
        
        if !hasActivePhotoImports {
            printDebug("No active photo imports - cleaning up temporary files")
            printDebug("About to call TempFileAccess.cleanupTemporaryFiles()")
            TempFileAccess.cleanupTemporaryFiles()
            printDebug("TempFileAccess.cleanupTemporaryFiles() completed")
        } else {
            printDebug("Active photo imports detected - keeping temp files")
            let activeCount = currentTasks.filter { $0.progress.state == .running }.count
            printDebug("Number of active imports: \(activeCount)")
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
