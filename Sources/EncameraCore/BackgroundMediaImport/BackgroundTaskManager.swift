//
//  BackgroundTaskManager.swift
//  EncameraCore
//
//  Created by Alexander Freas on 10.12.25.
//

import Foundation
import Combine

/// Closure type for task cancellation handlers
public typealias TaskCancellationHandler = () -> Void

/// Generic task manager for tracking and observing long-running background tasks.
/// Uses the BackgroundFileTask protocol to support any task type (imports, exports, etc.)
@MainActor
public class BackgroundTaskManager: ObservableObject, DebugPrintable {
    
    public static let shared = BackgroundTaskManager()
    
    // MARK: - Published Properties
    
    @Published public var currentTasks: [any BackgroundFileTask] = []
    @Published public var isProcessing: Bool = false
    @Published public var overallProgress: Double = 0.0
    
    // MARK: - Progress Publisher
    
    private var progressSubject = PassthroughSubject<ImportProgressUpdate, Never>()
    public var progressPublisher: AnyPublisher<ImportProgressUpdate, Never> {
        progressSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Cancellation Handlers
    
    /// Registered cancellation handlers for each task
    private var cancellationHandlers: [String: TaskCancellationHandler] = [:]
    
    // MARK: - Time Estimation State
    
    private var smoothedTimeEstimate: TimeInterval?
    private var lastTimeEstimateUpdate: Date?
    private var progressHistory: [(date: Date, progress: Double)] = []
    private let timeEstimateUpdateInterval: TimeInterval = 2.0
    private let smoothingFactor: Double = 0.3
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Task Lifecycle
    
    /// Adds a task to the manager and updates state
    public func addTask(_ task: any BackgroundFileTask) {
        printDebug("Adding task: \(task.id)")
        currentTasks.append(task)
        updateIsProcessing()
        printDebug("Total current tasks: \(currentTasks.count)")
    }
    
    /// Updates the progress for a specific task
    public func updateTaskProgress(taskId: String, progress: ImportProgressUpdate) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot update progress - task not found: \(taskId)")
            return
        }
        
        // We need to update the task - since BackgroundFileTask is a protocol,
        // we need to handle this through the concrete type
        if var importTask = currentTasks[taskIndex] as? ImportTask {
            importTask.progress = progress
            currentTasks[taskIndex] = importTask
            publishProgress(for: importTask)
        } else if var moveTask = currentTasks[taskIndex] as? MoveTask {
            moveTask.progress = progress
            currentTasks[taskIndex] = moveTask
            publishProgress(for: moveTask)
        }
    }
    
    /// Updates a task's state to running
    public func markTaskRunning(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot mark running - task not found: \(taskId)")
            return
        }
        
        if var importTask = currentTasks[taskIndex] as? ImportTask {
            importTask.progress.state = .running
            currentTasks[taskIndex] = importTask
            updateIsProcessing()
        } else if var moveTask = currentTasks[taskIndex] as? MoveTask {
            moveTask.progress.state = .running
            currentTasks[taskIndex] = moveTask
            updateIsProcessing()
        }
    }
    
    /// Updates a task's state to paused
    public func markTaskPaused(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot mark paused - task not found: \(taskId)")
            return
        }
        
        if var importTask = currentTasks[taskIndex] as? ImportTask {
            importTask.progress.state = .paused
            currentTasks[taskIndex] = importTask
            publishProgress(for: importTask)
        } else if var moveTask = currentTasks[taskIndex] as? MoveTask {
            moveTask.progress.state = .paused
            currentTasks[taskIndex] = moveTask
            publishProgress(for: moveTask)
        }
    }
    
    /// Updates a task's state to cancelled (internal use - prefer cancelTask for external callers)
    public func markTaskCancelled(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot mark cancelled - task not found: \(taskId)")
            return
        }
        
        if var importTask = currentTasks[taskIndex] as? ImportTask {
            importTask.progress.state = .cancelled
            currentTasks[taskIndex] = importTask
            publishProgress(for: importTask)
        } else if var moveTask = currentTasks[taskIndex] as? MoveTask {
            moveTask.progress.state = .cancelled
            currentTasks[taskIndex] = moveTask
            publishProgress(for: moveTask)
        }
    }
    
    // MARK: - Cancellation
    
    /// Registers a cancellation handler for a task
    /// The handler will be called when cancelTask is invoked for this task
    public func registerCancellationHandler(for taskId: String, handler: @escaping TaskCancellationHandler) {
        printDebug("Registering cancellation handler for task: \(taskId)")
        cancellationHandlers[taskId] = handler
    }
    
    /// Removes the cancellation handler for a task
    public func unregisterCancellationHandler(for taskId: String) {
        printDebug("Unregistering cancellation handler for task: \(taskId)")
        cancellationHandlers.removeValue(forKey: taskId)
    }
    
    /// Cancels a task by invoking its cancellation handler and updating state
    public func cancelTask(taskId: String) {
        printDebug("Cancelling task: \(taskId)")
        guard task(withId: taskId) != nil else {
            printDebug("Failed to find task to cancel: \(taskId)")
            return
        }
        
        // Call the registered cancellation handler if one exists
        if let handler = cancellationHandlers[taskId] {
            printDebug("Invoking cancellation handler for task: \(taskId)")
            handler()
        }
        
        // Mark the task as cancelled
        markTaskCancelled(taskId: taskId)
        
        // Remove the cancellation handler
        unregisterCancellationHandler(for: taskId)
        
        // Remove from active tasks after a delay to show cancelled state
        removeTaskAfterDelay(taskId: taskId)
    }
    
    /// Pauses a task by invoking its pause handler (if registered) and updating state
    public func pauseTask(taskId: String) {
        printDebug("Pausing task: \(taskId)")
        markTaskPaused(taskId: taskId)
    }
    
    /// Resumes a task - note: actual resume logic must be handled by the task owner
    public func resumeTask(taskId: String) {
        printDebug("Resuming task: \(taskId)")
        markTaskRunning(taskId: taskId)
    }
    
    /// Finalizes a task as completed
    public func finalizeTaskCompleted(taskId: String, totalItems: Int) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot finalize task - not found: \(taskId)")
            return
        }
        
        let completedProgress = ImportProgressUpdate(
            taskId: taskId,
            currentFileIndex: totalItems - 1,
            totalFiles: totalItems,
            currentFileProgress: 1.0,
            overallProgress: 1.0,
            currentFileName: nil,
            state: .completed,
            estimatedTimeRemaining: 0
        )
        
        if var importTask = currentTasks[taskIndex] as? ImportTask {
            importTask.progress = completedProgress
            currentTasks[taskIndex] = importTask
            publishProgress(for: importTask)
            printDebug("Task completed successfully: \(taskId)")
        } else if var moveTask = currentTasks[taskIndex] as? MoveTask {
            moveTask.progress = completedProgress
            currentTasks[taskIndex] = moveTask
            publishProgress(for: moveTask)
            printDebug("Task completed successfully: \(taskId)")
        }
        
        updateOverallProgress()
        updateIsProcessing()
    }
    
    /// Finalizes a task as failed
    public func finalizeTaskFailed(taskId: String, error: Error) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot finalize task - not found: \(taskId)")
            return
        }
        
        if var importTask = currentTasks[taskIndex] as? ImportTask {
            importTask.progress.state = .failed(error)
            currentTasks[taskIndex] = importTask
            publishProgress(for: importTask)
            printDebug("Task failed with error: \(error.localizedDescription) for task: \(taskId)")
        } else if var moveTask = currentTasks[taskIndex] as? MoveTask {
            moveTask.progress.state = .failed(error)
            currentTasks[taskIndex] = moveTask
            publishProgress(for: moveTask)
            printDebug("Task failed with error: \(error.localizedDescription) for task: \(taskId)")
        }
        
        updateOverallProgress()
        updateIsProcessing()
    }
    
    /// Removes a specific task by ID
    public func removeTask(taskId: String) {
        printDebug("Removing task: \(taskId)")
        currentTasks.removeAll { $0.id == taskId }
        updateOverallProgress()
        updateIsProcessing()
    }
    
    /// Removes a task after a delay (for showing cancelled/completed state briefly)
    public func removeTaskAfterDelay(taskId: String, delay: TimeInterval = 2.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.printDebug("Removing task after delay: \(taskId)")
            self.currentTasks.removeAll { $0.id == taskId }
            self.updateOverallProgress()
        }
    }
    
    /// Removes all completed, cancelled, or failed tasks
    public func clearCompletedTasks() {
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
    
    /// Clears all tasks and resets state
    public func clearAllTasks() {
        printDebug("Clearing all tasks and resetting state")
        
        let taskCount = currentTasks.count
        currentTasks.removeAll()
        printDebug("Cleared \(taskCount) tasks")
        
        overallProgress = 0.0
        updateOverallProgress()
        updateIsProcessing()
        resetTimeEstimationState()
        
        printDebug("All tasks cleared and state reset")
    }
    
    // MARK: - Task Queries
    
    /// Returns the task with the given ID, if it exists
    public func task(withId taskId: String) -> (any BackgroundFileTask)? {
        currentTasks.first { $0.id == taskId }
    }
    
    /// Returns the index of a task with the given ID
    public func taskIndex(withId taskId: String) -> Int? {
        currentTasks.firstIndex { $0.id == taskId }
    }
    
    /// Returns all active (running or paused) tasks
    public var activeTasks: [any BackgroundFileTask] {
        currentTasks.filter { task in
            switch task.progress.state {
            case .running, .paused:
                return true
            default:
                return false
            }
        }
    }
    
    // MARK: - Progress Tracking
    
    /// Publishes progress update for a task
    public func publishProgress(for task: any BackgroundFileTask) {
        if floor(task.progress.overallProgress * 100).truncatingRemainder(dividingBy: 10) == 0 {
            printDebug("Publishing progress for task \(task.id): \(task.progress.overallProgress * 100)% complete, \(task.progress.state)")
        }
        updateOverallProgress()
        progressSubject.send(task.progress)
    }
    
    /// Updates the overall progress across all active tasks
    public func updateOverallProgress() {
        let previousProgress = overallProgress
        
        let active = activeTasks
        
        if active.isEmpty {
            overallProgress = 0.0
        } else {
            let totalProgress = active.reduce(0.0) { $0 + $1.progress.overallProgress }
            overallProgress = totalProgress / Double(active.count)
        }
        
        if previousProgress != overallProgress {
            printDebug("Overall progress updated: \(previousProgress * 100)% -> \(overallProgress * 100)%, active tasks: \(active.map { $0.progress.state })")
        }
    }
    
    /// Updates the isProcessing flag based on current task states
    public func updateIsProcessing() {
        let wasProcessing = isProcessing
        isProcessing = currentTasks.contains { task in
            task.progress.state == .running
        }
        if wasProcessing != isProcessing {
            printDebug("Processing status changed: \(wasProcessing) -> \(isProcessing)")
        }
    }
    
    // MARK: - Time Estimation
    
    /// Calculates estimated time remaining with smoothing
    public func calculateEstimatedTime(startTime: Date, progress: Double) -> TimeInterval? {
        guard progress > 0.05 else {
            smoothedTimeEstimate = nil
            lastTimeEstimateUpdate = nil
            progressHistory.removeAll()
            return nil
        }
        
        let now = Date()
        
        progressHistory.append((date: now, progress: progress))
        
        let cutoffTime = now.addingTimeInterval(-30)
        progressHistory.removeAll { $0.date < cutoffTime }
        
        if let lastUpdate = lastTimeEstimateUpdate,
           now.timeIntervalSince(lastUpdate) < timeEstimateUpdateInterval,
           smoothedTimeEstimate != nil {
            return smoothedTimeEstimate
        }
        
        let newEstimate = calculateSmoothedEstimate(startTime: startTime, progress: progress, currentTime: now)
        
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
        
        if progressHistory.count >= 3 {
            let recentHistory = Array(progressHistory.suffix(min(10, progressHistory.count)))
            
            if recentHistory.count >= 2 {
                let timeSpan = recentHistory.last!.date.timeIntervalSince(recentHistory.first!.date)
                let progressSpan = recentHistory.last!.progress - recentHistory.first!.progress
                
                if timeSpan > 0 && progressSpan > 0 {
                    let progressRate = progressSpan / timeSpan
                    let remainingProgress = 1.0 - progress
                    let rateBasedEstimate = remainingProgress / progressRate
                    
                    let simpleEstimate = elapsed / progress - elapsed
                    let blendFactor = min(1.0, timeSpan / 10.0)
                    
                    return blendFactor * rateBasedEstimate + (1 - blendFactor) * simpleEstimate
                }
            }
        }
        
        let totalEstimate = elapsed / progress
        return totalEstimate - elapsed
    }
    
    /// Resets time estimation state for a new operation
    public func resetTimeEstimationState() {
        printDebug("Resetting time estimation smoothing state")
        smoothedTimeEstimate = nil
        lastTimeEstimateUpdate = nil
        progressHistory.removeAll()
    }
}
