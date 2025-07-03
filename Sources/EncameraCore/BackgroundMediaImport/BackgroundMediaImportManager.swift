import Foundation
import BackgroundTasks
import Combine
import UIKit

public enum ImportTaskState: Equatable {
    case idle
    case running
    case paused
    case completed
    case cancelled
    case failed(Error)
    
    public static func == (lhs: ImportTaskState, rhs: ImportTaskState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.running, .running),
             (.paused, .paused),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case (.failed(let lError), .failed(let rError)):
            return lError.localizedDescription == rError.localizedDescription
        default:
            return false
        }
    }
}

public struct ImportProgressUpdate {
    public let taskId: String
    public let currentFileIndex: Int
    public let totalFiles: Int
    public let currentFileProgress: Double
    public let overallProgress: Double
    public let currentFileName: String?
    public let state: ImportTaskState
    public let estimatedTimeRemaining: TimeInterval?
}

public struct ImportTask {
    public let id: String
    public let media: [CleartextMedia]
    public let albumId: String
    public let createdAt: Date
    public var state: ImportTaskState
    public var progress: ImportProgressUpdate
    
    public init(id: String = UUID().uuidString, media: [CleartextMedia], albumId: String) {
        self.id = id
        self.media = media
        self.albumId = albumId
        self.createdAt = Date()
        self.state = .idle
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: media.count,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }
}

@MainActor
public class BackgroundMediaImportManager: ObservableObject, DebugPrintable {
    
    public static let shared = BackgroundMediaImportManager()
    
    // MARK: - Published Properties
    @Published public var currentTasks: [ImportTask] = []
    @Published public var isImporting: Bool = false
    @Published public var overallProgress: Double = 0.0
    
    // MARK: - Private Properties
    private var fileAccess: FileAccess?
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
    
    private init() {
        setupNotificationObservers()
    }
    
    // MARK: - Public API
    
    public func configure(fileAccess: FileAccess, albumManager: AlbumManaging) {
        self.fileAccess = fileAccess
        self.albumManager = albumManager
    }
    
    public func startImport(media: [CleartextMedia], albumId: String) async throws {
        let task = ImportTask(media: media, albumId: albumId)
        currentTasks.append(task)
        
        try await executeImportTask(task)
    }
    
    public func pauseImport(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else { return }
        
        currentTasks[taskIndex].state = .paused
        currentImportTask?.cancel()
        
        publishProgress(for: currentTasks[taskIndex])
    }
    
    public func resumeImport(taskId: String) async throws {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }),
              currentTasks[taskIndex].state == .paused else { return }
        
        try await executeImportTask(currentTasks[taskIndex])
    }
    
    public func cancelImport(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else { return }
        
        currentTasks[taskIndex].state = .cancelled
        currentImportTask?.cancel()
        
        publishProgress(for: currentTasks[taskIndex])
        
        // Remove from active tasks after a delay to show cancelled state
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.currentTasks.removeAll { $0.id == taskId }
            self.updateOverallProgress()
        }
    }
    
    public func removeCompletedTasks() {
        currentTasks.removeAll { task in
            switch task.state {
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
        guard let fileAccess = fileAccess,
              let albumManager = albumManager,
              let album = albumManager.albums.first(where: { $0.id == task.albumId }) else {
            throw ImportError.configurationError
        }
        
        await configureFileAccess(for: album)
        
        let taskIndex = currentTasks.firstIndex(where: { $0.id == task.id })!
        currentTasks[taskIndex].state = .running
        isImporting = true
        
        startBackgroundTask()
        
        currentImportTask = Task {
            do {
                try await performImport(task: task, fileAccess: fileAccess)
                
                await MainActor.run {
                    if let index = self.currentTasks.firstIndex(where: { $0.id == task.id }) {
                        self.currentTasks[index].state = .completed
                        self.publishProgress(for: self.currentTasks[index])
                    }
                    self.updateIsImporting()
                    self.endBackgroundTask()
                }
            } catch {
                await MainActor.run {
                    if let index = self.currentTasks.firstIndex(where: { $0.id == task.id }) {
                        self.currentTasks[index].state = .failed(error)
                        self.publishProgress(for: self.currentTasks[index])
                    }
                    self.updateIsImporting()
                    self.endBackgroundTask()
                }
                throw error
            }
        }
        
        try await currentImportTask?.value
    }
    
    private func performImport(task: ImportTask, fileAccess: FileAccess) async throws {
        let startTime = Date()
        var processedFiles = 0
        
        // Process files concurrently in batches to avoid overwhelming the system
        let batchSize = 3
        let batches = task.media.chunked(into: batchSize)
        
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            
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
        }
    }
    
    private func processSingleFile(
        media: CleartextMedia,
        fileAccess: FileAccess,
        task: ImportTask,
        fileIndex: Int,
        startTime: Date,
        processedFiles: Int
    ) async throws {
        
        let interactableMedia = try InteractableMedia(underlyingMedia: [media])
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
                    self.updateOverallProgress()
                }
            }
        }
    }
    
    private func configureFileAccess(for album: Album) async {
        guard let albumManager = albumManager else { return }
        await fileAccess?.configure(for: album, albumManager: albumManager)
    }
    
    private func publishProgress(for task: ImportTask) {
        progressSubject.send(task.progress)
    }
    
    private func updateOverallProgress() {
        let activeTasks = currentTasks.filter { task in
            switch task.state {
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
    }
    
    private func updateIsImporting() {
        isImporting = currentTasks.contains { task in
            task.state == .running
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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.encamera.media-import", using: nil) { task in
            BackgroundMediaImportManager.shared.handleBackgroundImport(task: task as! BGProcessingTask)
        }
    }
    
    private func scheduleBackgroundImport() {
        let request = BGProcessingTaskRequest(identifier: "com.encamera.media-import")
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        
        try? BGTaskScheduler.shared.submit(request)
    }
    
    private func handleBackgroundImport(task: BGProcessingTask) {
        let hasActiveTasks = !currentTasks.filter { $0.state == .running || $0.state == .paused }.isEmpty
        
        if hasActiveTasks {
            // Continue processing in background
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            
            Task {
                // Resume or continue any paused/running tasks
                for importTask in currentTasks where importTask.state == .paused {
                    try? await resumeImport(taskId: importTask.id)
                }
                
                task.setTaskCompleted(success: true)
            }
        } else {
            task.setTaskCompleted(success: true)
        }
    }
    
    private func startBackgroundTask() {
        endBackgroundTask() // End any existing task
        
        activeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MediaImport") {
            self.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if activeBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(activeBackgroundTask)
            activeBackgroundTask = .invalid
        }
    }
    
    // MARK: - Notification Observers
    
    private func setupNotificationObservers() {
        NotificationUtils.didEnterBackgroundPublisher
            .sink { [weak self] _ in
                self?.scheduleBackgroundImport()
            }
            .store(in: &cancellables)
        
        NotificationUtils.willEnterForegroundPublisher
            .sink { [weak self] _ in
                // Refresh task states when returning to foreground
                Task { @MainActor in
                    self?.updateOverallProgress()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Supporting Types

public enum ImportError: Error {
    case configurationError
    case taskNotFound
    case operationCancelled
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
} 