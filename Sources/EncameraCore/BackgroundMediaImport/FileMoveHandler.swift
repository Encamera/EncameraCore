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
    /// The user cancelled the move; the counts cover the items handled before it.
    public let wasCancelled: Bool

    public init(successCount: Int, failureCount: Int, targetAlbumName: String, wasCancelled: Bool = false) {
        self.successCount = successCount
        self.failureCount = failureCount
        self.targetAlbumName = targetAlbumName
        self.wasCancelled = wasCancelled
    }
}

// MARK: - File Move Handler

/// Handles all move-specific logic for moving media between encrypted albums.
/// Uses BackgroundTaskManager for task state management.
@MainActor
public class FileMoveHandler: DebugPrintable {
    
    public static let shared = FileMoveHandler()

    /// A pause before each item, set by UI tests that cancel a move part-way.
    nonisolated(unsafe) public static var itemDelayForTesting: TimeInterval?
    
    // MARK: - Dependencies
    
    private let taskManager: BackgroundTaskManager
    private var albumManager: AlbumManaging?
    /// Builds the destination album's file access. Injectable for tests.
    private let makeFileAccess: (Album, AlbumManaging) async -> FileAccess
    
    // MARK: - Private Properties
    
    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    private var currentMoveTask: Task<MoveResult, Error>?
    
    // MARK: - Initialization
    
    public init(taskManager: BackgroundTaskManager = .shared,
                makeFileAccess: ((Album, AlbumManaging) async -> FileAccess)? = nil) {
        self.taskManager = taskManager
        self.makeFileAccess = makeFileAccess ?? { album, albumManager in
            await InteractableMediaFileAccess(for: album, albumManager: albumManager)
        }
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
        
        guard let albumManager = albumManager else {
            printDebug("Failed to start move - albumManager not configured")
            throw BackgroundImportError.configurationError
        }
        
        let task = createAndRegisterTask(
            media: media,
            sourceAlbumId: sourceAlbumId,
            targetAlbum: targetAlbum
        )
        
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
        
        let availableAlbums = albumManager.fetchAlbumsFromSources(includingHidden: true)

        guard let targetAlbum = availableAlbums.first(where: { $0.id == task.targetAlbumId }) else {
            printDebug("Failed to find target album: \(task.targetAlbumId)")
            throw BackgroundImportError.configurationError
        }
        
        taskManager.markTaskRunning(taskId: task.id)
        
        printDebug("Starting background task for move: \(task.id)")
        startBackgroundTask()
        taskManager.resetTimeEstimationState()
        
        var result: MoveResult = MoveResult(successCount: 0, failureCount: 0, targetAlbumName: task.targetAlbumName)
        
        let sourceAlbum = availableAlbums.first { $0.id == task.sourceAlbumId }
        currentMoveTask = Task {
            let fileAccess = await makeFileAccess(targetAlbum, albumManager)
            let counts = await performMove(task: task, fileAccess: fileAccess) { moved in
                guard let sourceAlbum else { return }
                albumManager.resetAlbumCover(album: sourceAlbum, ifItIs: moved.id)
            }
            return MoveResult(
                successCount: counts.success,
                failureCount: counts.failure,
                targetAlbumName: task.targetAlbumName,
                wasCancelled: counts.cancelled
            )
        }
        
        do {
            result = try await currentMoveTask!.value
            await MainActor.run {
                if result.wasCancelled {
                    self.printDebug("Move was cancelled after \(result.successCount) item(s)")
                    self.taskManager.finalizeTaskCancelled(taskId: task.id)
                } else {
                    self.taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: task.mediaToMove.count)
                }
                self.endBackgroundTask()
            }
        } catch is CancellationError {
            result = MoveResult(successCount: 0, failureCount: 0, targetAlbumName: task.targetAlbumName, wasCancelled: true)
            await MainActor.run {
                self.printDebug("Move was cancelled")
                self.taskManager.finalizeTaskCancelled(taskId: task.id)
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
    
    /// Moves every item in turn. A cancel takes effect between items only: the item
    /// under way always finishes, so none is left with some components moved and the
    /// rest still in the source. `didMove` runs once for each item that moved.
    private func performMove(
        task: MoveTask,
        fileAccess: FileAccess,
        didMove: (InteractableMedia<EncryptedMedia>) -> Void
    ) async -> (success: Int, failure: Int, cancelled: Bool) {
        printDebug("Performing move for task: \(task.id) with \(task.mediaToMove.count) items")
        let startTime = Date()
        var processedCount = 0
        var successCount = 0
        var failureCount = 0
        
        for (index, media) in task.mediaToMove.enumerated() {
            if let delay = Self.itemDelayForTesting {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if Task.isCancelled {
                printDebug("📈 Move cancelled - Moved \(successCount)/\(task.mediaToMove.count) (Failed: \(failureCount))")
                return (successCount, failureCount, true)
            }
            
            let needsDownload = media.needsDownload
            if needsDownload {
                printDebug("📦 Moving item \(index + 1)/\(task.mediaToMove.count) (requires iCloud download)")
            } else {
                printDebug("📦 Moving item \(index + 1)/\(task.mediaToMove.count)")
            }
            
            do {
                let progressCallback: (FileLoadingStatus) -> Void = { [weak self] status in
                    guard let self = self else { return }
                    Task { @MainActor in
                        switch status {
                        case .downloading(let downloadProgress):
                            self.printDebug("📥 Downloading from iCloud: \(Int(downloadProgress * 100))%")
                            let itemProgress = downloadProgress
                            let overallProgress = (Double(processedCount) + itemProgress) / Double(task.mediaToMove.count)
                            let estimatedTimeRemaining = self.taskManager.calculateEstimatedTime(startTime: startTime, progress: overallProgress)
                            
                            let progress = ImportProgressUpdate(
                                taskId: task.id,
                                currentFileIndex: index,
                                totalFiles: task.mediaToMove.count,
                                currentFileProgress: itemProgress,
                                overallProgress: overallProgress,
                                currentFileName: needsDownload ? "Downloading from iCloud..." : nil,
                                state: .running,
                                estimatedTimeRemaining: estimatedTimeRemaining
                            )
                            self.taskManager.updateTaskProgress(taskId: task.id, progress: progress)
                        default:
                            break
                        }
                    }
                }
                
                // An unstructured task does not inherit this task's cancellation.
                try await Task { try await fileAccess.move(media: media, progress: progressCallback) }.value
                didMove(media)
                successCount += 1
                processedCount += 1
                printDebug("✅ Successfully moved item \(index + 1)/\(task.mediaToMove.count)")
            } catch {
                failureCount += 1
                processedCount += 1
                printDebug("❌ Error moving item \(index + 1): \(error)")
            }
            
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
        return (successCount, failureCount, false)
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
                    try? await Task.sleep(nanoseconds: 500_000_000)
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
