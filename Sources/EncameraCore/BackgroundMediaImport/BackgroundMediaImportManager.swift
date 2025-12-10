//
//  BackgroundMediaImportManager.swift
//  EncameraCore
//
//  Facade that maintains backward compatibility while delegating to
//  BackgroundTaskManager (task management) and MediaImportHandler (import logic).
//

import Foundation
import Combine

/// Facade for background media import operations.
/// Delegates to BackgroundTaskManager for task management and MediaImportHandler for import logic.
/// Maintained for backward compatibility with existing code.
@MainActor
public class BackgroundMediaImportManager: ObservableObject, DebugPrintable {
    
    public static let shared = BackgroundMediaImportManager()
    
    // MARK: - Dependencies
    
    private let taskManager: BackgroundTaskManager
    private let importHandler: MediaImportHandler
    
    // MARK: - Published Properties (forwarded from taskManager)
    
    /// Current import tasks - forwards to taskManager but filters to ImportTask type
    @Published public var currentTasks: [ImportTask] = []
    
    /// Whether any import is currently running
    @Published public var isImporting: Bool = false
    
    /// Overall progress across all active imports
    @Published public var overallProgress: Double = 0.0
    
    // MARK: - Progress Publisher
    
    public var progressPublisher: AnyPublisher<ImportProgressUpdate, Never> {
        taskManager.progressPublisher
    }
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(taskManager: BackgroundTaskManager = .shared, importHandler: MediaImportHandler = .shared) {
        self.taskManager = taskManager
        self.importHandler = importHandler
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Forward taskManager's currentTasks (filtered to ImportTask) to our published property
        taskManager.$currentTasks
            .map { tasks in
                tasks.compactMap { $0 as? ImportTask }
            }
            .assign(to: &$currentTasks)
        
        // Forward isProcessing as isImporting
        taskManager.$isProcessing
            .assign(to: &$isImporting)
        
        // Forward overall progress
        taskManager.$overallProgress
            .assign(to: &$overallProgress)
    }
    
    // MARK: - Public Configuration
    
    public func configure(albumManager: AlbumManaging) {
        printDebug("Configuring BackgroundMediaImportManager with albumManager")
        importHandler.configure(albumManager: albumManager)
    }
    
    // MARK: - Public Import API
    
    /// High-level API: Start import directly from MediaSelectionResults (PHAssets or PHPickerResults)
    /// This handles the complete flow: load each item, import it, then cleanup its temp files atomically.
    /// Uses streaming mode for memory efficiency - items are loaded one at a time.
    /// Returns a summary of successful and failed imports.
    @discardableResult
    public func startImport(results: [MediaSelectionResult], albumId: String, source: ImportSource) async throws -> (success: Int, failure: Int) {
        try await importHandler.startImport(results: results, albumId: albumId, source: source)
    }
    
    /// Start import from preloaded media (e.g., from Files app or Share Extension)
    public func startImport(media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = [], userBatchId: String? = nil) async throws {
        try await importHandler.startImport(media: media, albumId: albumId, source: source, assetIdentifiers: assetIdentifiers, userBatchId: userBatchId)
    }
    
    /// Pauses an in-progress import task
    public func pauseImport(taskId: String) {
        importHandler.pauseImport(taskId: taskId)
    }
    
    /// Resumes a paused import task
    public func resumeImport(taskId: String) async throws {
        try await importHandler.resumeImport(taskId: taskId)
    }
    
    /// Cancels an import task
    public func cancelImport(taskId: String) {
        importHandler.cancelImport(taskId: taskId)
    }
    
    // MARK: - Task Management (forwarded to taskManager)
    
    /// Removes all completed, cancelled, or failed tasks
    public func removeCompletedTasks() {
        taskManager.clearCompletedTasks()
    }
    
    /// Removes a specific task by ID
    public func removeTask(taskId: String) {
        taskManager.removeTask(taskId: taskId)
    }
    
    /// Clears all tasks and resets state
    public func clearAllTasks() {
        taskManager.clearAllTasks()
    }
}
