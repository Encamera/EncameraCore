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
/// A cancellation handler that may refuse: returns whether the task will stop.
public typealias RefusableTaskCancellationHandler = () -> Bool

/// Why a task was taken out of `BackgroundTaskManager.currentTasks`. Logged with
/// every removal so a device log names what removed a task.
public enum TaskRemovalReason: String {
    /// `cancelTask` found no cancellation handler for the task.
    case cancelledWithoutHandler
    /// The task stopped (cancelled or failed) without importing anything.
    case stoppedWithNothingImported
    /// The task's originals were deleted from the photo library.
    case originalsDeleted
    /// `clearCompletedTasks` swept finished tasks.
    case clearCompleted
    /// `clearAllTasks` reset the manager.
    case clearAll
}

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
    
    private enum CancellationHandler {
        /// Always stops the task; runs after the task is marked cancelled.
        case unconditional(TaskCancellationHandler)
        /// Decides whether the task stops; the task is marked cancelled only if so.
        case refusable(RefusableTaskCancellationHandler)
    }

    /// Registered cancellation handlers for each task
    private var cancellationHandlers: [String: CancellationHandler] = [:]
    
    // MARK: - Time Estimation State
    
    private var smoothedTimeEstimate: TimeInterval?
    private var lastTimeEstimateUpdate: Date?
    private var progressHistory: [(date: Date, progress: Double)] = []
    private let timeEstimateUpdateInterval: TimeInterval = 2.0
    private let smoothingFactor: Double = 0.3
    
    // MARK: - Initialization
    
    /// How long a stopped task stays visible before `removeTaskAfterDelay` removes it.
    private let removalDelay: TimeInterval

    public init(removalDelay: TimeInterval = 2.0) {
        self.removalDelay = removalDelay
    }
    
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
        
        // A stopped task keeps its state; only `markTaskRunning` makes a task running.
        let storedState = currentTasks[taskIndex].progress.state
        var update = progress
        switch storedState {
        case .cancelled, .completed, .failed:
            update.state = storedState
        default:
            break
        }
        currentTasks[taskIndex].progress = update
        publishProgress(for: currentTasks[taskIndex])
    }

    /// Updates a task's state to running
    public func markTaskRunning(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot mark running - task not found: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = .running
        updateIsProcessing()
    }

    /// Updates a task's state to paused
    public func markTaskPaused(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot mark paused - task not found: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = .paused
        publishProgress(for: currentTasks[taskIndex])
    }

    /// Updates a task's state to cancelled (internal use - prefer cancelTask for external callers)
    /// Note: This does NOT update isProcessing - the task is still considered "in progress"
    /// until finalizeTaskCancelled is called. This ensures proper cleanup timing.
    public func markTaskCancelled(taskId: String) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot mark cancelled - task not found: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = .cancelled
        publishProgress(for: currentTasks[taskIndex])
    }
    
    // MARK: - Cancellation
    
    /// Registers a cancellation handler for a task
    /// The handler will be called when cancelTask is invoked for this task
    public func registerCancellationHandler(for taskId: String, handler: @escaping TaskCancellationHandler) {
        printDebug("Registering cancellation handler for task: \(taskId)")
        cancellationHandlers[taskId] = .unconditional(handler)
    }

    /// Registers a handler that can refuse the cancel, for a task that cannot stop
    /// at every point. On a refusal `cancelTask` leaves the task running and the
    /// handler registered, so the task is never shown as cancelled while its work
    /// goes on.
    public func registerRefusableCancellationHandler(for taskId: String,
                                                     handler: @escaping RefusableTaskCancellationHandler) {
        printDebug("Registering refusable cancellation handler for task: \(taskId)")
        cancellationHandlers[taskId] = .refusable(handler)
    }
    
    /// Removes the cancellation handler for a task
    public func unregisterCancellationHandler(for taskId: String) {
        printDebug("Unregistering cancellation handler for task: \(taskId)")
        cancellationHandlers.removeValue(forKey: taskId)
    }
    
    /// Cancels a task by invoking its cancellation handler and updating state.
    /// Note: The task is NOT automatically removed - the handler is responsible for calling
    /// finalizeTaskCancelled() which will decide whether to keep the task (for partial imports)
    /// or remove it after a delay.
    /// A handler registered with `registerRefusableCancellationHandler(for:handler:)` can
    /// refuse, which leaves the task's state and handler untouched.
    public func cancelTask(taskId: String) {
        printDebug("Cancelling task: \(taskId)")
        guard let existing = task(withId: taskId) else {
            printDebug("Failed to find task to cancel: \(taskId)")
            return
        }
        if existing.progress.state == .cancelled {
            printDebug("Cancel ignored - task \(taskId) is already cancelling")
            return
        }

        switch cancellationHandlers[taskId] {
        case .refusable(let handler)?:
            printDebug("Cancel task \(taskId) branch=refusable state=\(existing.progress.state)")
            guard handler() else {
                printDebug("Cancellation refused for task: \(taskId)")
                return
            }
            markTaskCancelled(taskId: taskId)
        case .unconditional(let handler)?:
            printDebug("Cancel task \(taskId) branch=unconditional state=\(existing.progress.state)")
            markTaskCancelled(taskId: taskId)
            printDebug("Invoking cancellation handler for task: \(taskId)")
            handler()
        case nil:
            printDebug("Cancel task \(taskId) branch=noHandler state=\(existing.progress.state)")
            markTaskCancelled(taskId: taskId)
            removeTaskAfterDelay(taskId: taskId, reason: .cancelledWithoutHandler)
        }

        unregisterCancellationHandler(for: taskId)
    }
    
    /// Finalizes a task as completed
    public func finalizeTaskCompleted(taskId: String, totalItems: Int, assetIdentifiers: [String] = [], mediaIdsByAssetId: [String: String]? = nil) {
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
        
        currentTasks[taskIndex].progress = completedProgress
        applyAssetIdentifiers(assetIdentifiers, mediaIdsByAssetId: mediaIdsByAssetId, at: taskIndex)
        publishProgress(for: currentTasks[taskIndex])
        printDebug("Task completed successfully: \(taskId)")

        updateOverallProgress()
        updateIsProcessing()
    }

    /// Finalizes a task as failed
    public func finalizeTaskFailed(taskId: String, error: Error) {
        finalizeTaskStopped(taskId: taskId, state: .failed(error), assetIdentifiers: [], shouldRemove: false)
        printDebug("Task failed with error: \(error.localizedDescription) for task: \(taskId)")
    }
    
    /// Finalizes a task as cancelled with optional partial results.
    /// If assetIdentifiers are provided, they are stored on the task for later deletion from photo library.
    /// Tasks with partial imports (assetIdentifiers > 0) are kept so the progress pill
    /// can still offer to delete them; the lasting record is the album's import history.
    /// Tasks without partial imports are removed after a delay.
    public func finalizeTaskCancelled(taskId: String, assetIdentifiers: [String] = [], mediaIdsByAssetId: [String: String]? = nil) {
        let shouldRemove = assetIdentifiers.isEmpty
        finalizeTaskStopped(taskId: taskId, state: .cancelled, assetIdentifiers: assetIdentifiers,
                            mediaIdsByAssetId: mediaIdsByAssetId, shouldRemove: shouldRemove)
        
        if !assetIdentifiers.isEmpty {
            printDebug("Keeping cancelled task \(taskId) with \(assetIdentifiers.count) partial imports")
        }
    }
    
    /// Private helper to finalize a task that has stopped (failed or cancelled).
    private func finalizeTaskStopped(taskId: String, state: FileTaskState, assetIdentifiers: [String],
                                     mediaIdsByAssetId: [String: String]? = nil, shouldRemove: Bool) {
        guard let taskIndex = currentTasks.firstIndex(where: { $0.id == taskId }) else {
            printDebug("Cannot finalize task - not found: \(taskId)")
            return
        }
        
        currentTasks[taskIndex].progress.state = state
        applyAssetIdentifiers(assetIdentifiers, mediaIdsByAssetId: mediaIdsByAssetId, at: taskIndex)
        publishProgress(for: currentTasks[taskIndex])

        if shouldRemove {
            removeTaskAfterDelay(taskId: taskId, reason: .stoppedWithNothingImported)
        }

        updateOverallProgress()
        updateIsProcessing()
    }

    /// Stores partial-import asset identifiers on the task at `taskIndex`.
    /// Only `ImportTask` tracks them — every other task type imports nothing from
    /// the photo library, so this is a no-op for them, exactly as before.
    private func applyAssetIdentifiers(_ assetIdentifiers: [String], mediaIdsByAssetId: [String: String]?, at taskIndex: Int) {
        guard !assetIdentifiers.isEmpty,
              let importTask = currentTasks[taskIndex] as? ImportTask else {
            return
        }
        currentTasks[taskIndex] = importTask.withAssetIdentifiers(assetIdentifiers, mediaIdsByAssetId: mediaIdsByAssetId)
        printDebug("Updated task \(importTask.id) with \(assetIdentifiers.count) asset identifiers")
    }

    /// Removes a specific task by ID
    public func removeTask(taskId: String, reason: TaskRemovalReason,
                           file: StaticString = #fileID, line: UInt = #line) {
        logRemoval(taskId: taskId, reason: reason, file: file, line: line)
        currentTasks.removeAll { $0.id == taskId }
        updateOverallProgress()
        updateIsProcessing()
    }
    
    /// Removes a task after a delay (for showing cancelled/completed state briefly)
    public func removeTaskAfterDelay(taskId: String, delay: TimeInterval? = nil, reason: TaskRemovalReason,
                                     file: StaticString = #fileID, line: UInt = #line) {
        let delay = delay ?? removalDelay
        printDebug("Scheduling removal of task \(taskId) in \(delay)s state=\(task(withId: taskId).map { "\($0.progress.state)" } ?? "missing") reason=\(reason) caller=\(file):\(line)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.logRemoval(taskId: taskId, reason: reason, file: file, line: line)
            self.currentTasks.removeAll { $0.id == taskId }
            self.updateOverallProgress()
        }
    }

    /// Writes the one log line every removal leaves: id, type, state, reason and
    /// caller, as a warning when the task is still running or paused.
    private func logRemoval(taskId: String, reason: TaskRemovalReason, file: StaticString, line: UInt) {
        guard let removed = task(withId: taskId) else {
            printDebug("Removing task \(taskId) - already gone reason=\(reason) caller=\(file):\(line)")
            return
        }
        logRemoval(of: removed, reason: reason, caller: "\(file):\(line)")
    }

    private func logRemoval(of removed: any BackgroundFileTask, reason: TaskRemovalReason, caller: String) {
        let details = "\(removed.id) type=\(removed.taskType) state=\(removed.progress.state) reason=\(reason) caller=\(caller)"
        switch removed.progress.state {
        case .running, .paused:
            printDebug("⚠️ Removing a running task \(details)")
        default:
            printDebug("Removing task \(details)")
        }
    }
    
    /// Removes all completed, cancelled, or failed tasks
    public func clearCompletedTasks(file: StaticString = #fileID, line: UInt = #line) {
        let tasksToRemove = currentTasks.filter { task in
            switch task.progress.state {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
        
        printDebug("Removing \(tasksToRemove.count) completed/cancelled/failed tasks")
        for removed in tasksToRemove {
            logRemoval(of: removed, reason: .clearCompleted, caller: "\(file):\(line)")
        }
        let removedIds = Set(tasksToRemove.map(\.id))
        currentTasks.removeAll { removedIds.contains($0.id) }
        updateOverallProgress()
    }
    
    /// Clears all tasks and resets state
    public func clearAllTasks(file: StaticString = #fileID, line: UInt = #line) {
        printDebug("Clearing all tasks and resetting state")
        
        let taskCount = currentTasks.count
        for removed in currentTasks {
            logRemoval(of: removed, reason: .clearAll, caller: "\(file):\(line)")
        }
        currentTasks.removeAll()
        printDebug("Cleared \(taskCount) tasks")
        
        overallProgress = 0.0
        updateOverallProgress()
        updateIsProcessing()
        resetTimeEstimationState()
        
        printDebug("All tasks cleared and state reset")
    }
    
    // MARK: - Task Queries
    
    /// Whether a task with the given ID is still tracked.
    public func hasTask(_ taskId: String) -> Bool {
        task(withId: taskId) != nil
    }

    /// Returns the task with the given ID, if it exists
    public func task(withId taskId: String) -> (any BackgroundFileTask)? {
        currentTasks.first { $0.id == taskId }
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
