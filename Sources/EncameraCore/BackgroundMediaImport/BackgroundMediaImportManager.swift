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

    public func startImport(media: [CleartextMedia], albumId: String, assetIdentifiers: [String] = []) async throws {
        printDebug("Starting import for \(media.count) media items to album: \(albumId) with \(assetIdentifiers.count) asset identifiers")
        let task = ImportTask(media: media, albumId: albumId, assetIdentifiers: assetIdentifiers)
        currentTasks.append(task)
        
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
                    
                    // Clean up temp files if no other imports are running
                    if !self.isImporting {
                        self.printDebug("No more active imports - cleaning up temp files")
                        TempFileAccess.cleanupTemporaryFiles()
                    }
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
                    
                    // Clean up temp files if no other imports are running
                    if !self.isImporting {
                        self.printDebug("No more active imports after failure - cleaning up temp files")
                        TempFileAccess.cleanupTemporaryFiles()
                    }
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
        
        // Log the source URL to track temp file usage
        if case .url(let sourceURL) = media.source {
            printDebug("Source file URL: \(sourceURL.path)")
            if !FileManager.default.fileExists(atPath: sourceURL.path) {
                printDebug("WARNING: Source file does not exist at path: \(sourceURL.path)")
            }
        }
        
        let interactableMedia = try InteractableMedia(underlyingMedia: [media])
        
        do {
            try await fileAccess.save(media: interactableMedia) { fileProgress in
                Task { @MainActor in
                    let overallProgress = (Double(processedFiles) + fileProgress) / Double(task.media.count)
                    let estimatedTimeRemaining = self.calculateEstimatedTime(
                        startTime: startTime,
                        progress: overallProgress
                    )
                    
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
            
            // Check if it's a file not found error
            if let nsError = error as NSError?, 
               nsError.domain == NSCocoaErrorDomain && nsError.code == 4 {
                printDebug("File not found error - likely temp files were cleaned up")
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
