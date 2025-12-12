//
//  FileMoveHandler.swift
//  EncameraCore
//
//  Created by Alexander Freas on 10.12.25.
//

import Foundation
import Combine
import UIKit

// MARK: - Move Result

/// Result of a move operation
public struct MoveResult {
    public let successCount: Int
    public let failureCount: Int
    public let targetAlbumName: String
}

// MARK: - File Move Handler

/// Handles all move-specific logic for moving media between encrypted albums.
/// Uses BackgroundTaskManager for task state management.
@MainActor
public class FileMoveHandler: DebugPrintable {
    
    public static let shared = FileMoveHandler()
    
    // MARK: - Dependencies
    
    private let taskManager: BackgroundTaskManager
    private var albumManager: AlbumManaging?
    
    // MARK: - Private Properties
    
    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    private var currentMoveTask: Task<MoveResult, Error>?
    
    // MARK: - Initialization
    
    public init(taskManager: BackgroundTaskManager = .shared) {
        self.taskManager = taskManager
        setupNotificationObservers()
    }
    
    // MARK: - Public Configuration
    
    public func configure(albumManager: AlbumManaging) {
        printDebug("Configuring FileMoveHandler with albumManager")
        self.albumManager = albumManager
    }
    
    // MARK: - Public Move API
    
    /// Start moving media from source album to target album
    /// Returns a MoveResult with counts of successful and failed moves
    @discardableResult
    public func startMove(
        media: [InteractableMedia<EncryptedMedia>],
        sourceAlbumId: String,
        targetAlbum: Album
    ) async throws -> MoveResult {
        printDebug("Starting move of \(media.count) items from album \(sourceAlbumId) to album \(targetAlbum.id)")
        
        // Validate configuration upfront
        guard let albumManager = albumManager else {
            printDebug("Failed to start move - albumManager not configured")
            throw BackgroundImportError.configurationError
        }
        
        // Create and register the task
        let task = createAndRegisterTask(
            media: media,
            sourceAlbumId: sourceAlbumId,
            targetAlbum: targetAlbum
        )
        
        // Execute the move task
        return try await executeMoveTask(task, albumManager: albumManager)
    }
    
    /// Cancels a move task - delegates to BackgroundTaskManager
    public func cancelMove(taskId: String) {
        printDebug("Cancelling move task: \(taskId)")
        taskManager.cancelTask(taskId: taskId)
    }
    
    // MARK: - Task Creation
    
    /// Creates and registers a new move task with the manager
    private func createAndRegisterTask(
        media: [InteractableMedia<EncryptedMedia>],
        sourceAlbumId: String,
        targetAlbum: Album
    ) -> MoveTask {
        let taskId = UUID().uuidString
        
        let task = MoveTask(
            id: taskId,
            mediaToMove: media,
            sourceAlbumId: sourceAlbumId,
            targetAlbumId: targetAlbum.id,
            targetAlbumName: targetAlbum.name
        )
        
        taskManager.addTask(task)
        
        // Register cancellation handler so BackgroundTaskManager can cancel this task
        taskManager.registerCancellationHandler(for: taskId) { [weak self] in
            self?.printDebug("Cancellation handler invoked for move task: \(taskId)")
            self?.currentMoveTask?.cancel()
        }
        
        printDebug("Created move task with ID: \(taskId) for \(media.count) items")
        
        return task
    }
    
    // MARK: - Move Execution
    
    /// Executes the move task
    private func executeMoveTask(_ task: MoveTask, albumManager: AlbumManaging) async throws -> MoveResult {
        printDebug("Executing move task: \(task.id)")
        
        // Reload albums to ensure we have current state
        albumManager.loadAlbumsFromFilesystem()
        
        guard let targetAlbum = albumManager.albums.first(where: { $0.id == task.targetAlbumId }) else {
            printDebug("Failed to find target album: \(task.targetAlbumId)")
            throw BackgroundImportError.configurationError
        }
        
        taskManager.markTaskRunning(taskId: task.id)
        
        printDebug("Starting background task for move: \(task.id)")
        startBackgroundTask()
        taskManager.resetTimeEstimationState()
        
        var result: MoveResult = MoveResult(successCount: 0, failureCount: 0, targetAlbumName: task.targetAlbumName)
        
        currentMoveTask = Task {
            let fileAccess = await InteractableMediaDiskAccess(for: targetAlbum, albumManager: albumManager)
            let counts = try await performMove(task: task, fileAccess: fileAccess)
            return MoveResult(
                successCount: counts.success,
                failureCount: counts.failure,
                targetAlbumName: task.targetAlbumName
            )
        }
        
        do {
            result = try await currentMoveTask!.value
            await MainActor.run {
                self.taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: task.mediaToMove.count)
                self.endBackgroundTask()
            }
        } catch {
            await MainActor.run {
                self.taskManager.finalizeTaskFailed(taskId: task.id, error: error)
                self.endBackgroundTask()
            }
            throw error
        }
        
        return result
    }
    
    /// Performs the actual move operation for all media items
    private func performMove(
        task: MoveTask,
        fileAccess: FileAccess
    ) async throws -> (success: Int, failure: Int) {
        printDebug("Performing move for task: \(task.id) with \(task.mediaToMove.count) items")
        let startTime = Date()
        var processedCount = 0
        var successCount = 0
        var failureCount = 0
        
        for (index, media) in task.mediaToMove.enumerated() {
            // Check for cancellation
            guard let currentTask = await MainActor.run(body: { taskManager.task(withId: task.id) }),
                  await MainActor.run(body: { currentTask.progress.state == .running }) else {
                printDebug("Move task \(task.id) was cancelled or not found, stopping")
                break
            }
            
            printDebug("📦 Moving item \(index + 1)/\(task.mediaToMove.count)")
            
            do {
                try await fileAccess.move(media: media)
                successCount += 1
                processedCount += 1
                printDebug("✅ Successfully moved item \(index + 1)/\(task.mediaToMove.count)")
            } catch {
                failureCount += 1
                processedCount += 1
                printDebug("❌ Error moving item \(index + 1): \(error)")
            }
            
            // Update progress after each item
            await MainActor.run {
                updateMoveProgress(
                    task: task,
                    currentIndex: index,
                    totalItems: task.mediaToMove.count,
                    processedCount: processedCount,
                    startTime: startTime
                )
            }
        }
        
        printDebug("📈 Move complete - Processed: \(processedCount)/\(task.mediaToMove.count) (Success: \(successCount), Failed: \(failureCount))")
        return (successCount, failureCount)
    }
    
    /// Updates progress during move operation
    private func updateMoveProgress(
        task: MoveTask,
        currentIndex: Int,
        totalItems: Int,
        processedCount: Int,
        startTime: Date
    ) {
        let overallProgress = Double(processedCount) / Double(totalItems)
        let estimatedTimeRemaining = taskManager.calculateEstimatedTime(startTime: startTime, progress: overallProgress)
        
        let progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: currentIndex,
            totalFiles: totalItems,
            currentFileProgress: 1.0, // Each item is atomic
            overallProgress: overallProgress,
            currentFileName: nil,
            state: .running,
            estimatedTimeRemaining: estimatedTimeRemaining
        )
        
        taskManager.updateTaskProgress(taskId: task.id, progress: progress)
    }
    
    // MARK: - Background Task Management
    
    private func startBackgroundTask() {
        printDebug("Starting UIBackgroundTask for move")
        endBackgroundTask()
        
        activeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MediaMove") {
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
                self?.printDebug("App will enter foreground - refreshing move task states")
                Task { @MainActor in
                    // Delay non-critical work to let biometric authentication complete first
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    self?.taskManager.updateOverallProgress()
                }
            }
            .store(in: &cancellables)
        
        NotificationUtils.willResignActivePublisher
            .sink { [weak self] _ in
                self?.printDebug("App will resign active - preparing for background")
            }
            .store(in: &cancellables)
    }
}
