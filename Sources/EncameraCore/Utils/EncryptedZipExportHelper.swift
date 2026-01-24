//
//  EncryptedZipExportHelper.swift
//  EncameraCore
//
//  Created by Alexander Freas on 03.01.26.
//

import Foundation
import ZipArchive
import UIKit

/// Progress reporting enum for zip export operations
public enum ZipExportProgress: Equatable {
    case decrypting(current: Int, total: Int, percent: Double)
    case compressing(percent: Double)
    case completed
}

/// Errors that can occur during zip export
public enum ZipExportError: Error, ErrorDescribable {
    case noMediaToExport
    case decryptionFailed(String)
    case zipCreationFailed(String)
    case emptyPassword
    case directoryCreationFailed(String)
    case backgroundTimeExpired
    
    public var displayDescription: String {
        switch self {
        case .noMediaToExport:
            return L10n.ZipExportError.noMediaToExport
        case .decryptionFailed(let message):
            return L10n.ZipExportError.decryptionFailed(message)
        case .zipCreationFailed(let message):
            return L10n.ZipExportError.zipCreationFailed(message)
        case .emptyPassword:
            return L10n.ZipExportError.emptyPassword
        case .directoryCreationFailed(let message):
            return L10n.ZipExportError.directoryCreationFailed(message)
        case .backgroundTimeExpired:
            return L10n.ZipExportError.backgroundTimeExpired
        }
    }
}

/// Helper class for exporting encrypted media as a password-protected zip file
public class EncryptedZipExportHelper: DebugPrintable {
    
    // MARK: - Properties
    
    private let fileAccess: FileAccess
    private let media: [InteractableMedia<EncryptedMedia>]
    private let taskManager: BackgroundTaskManager
    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTimeExpired: Bool = false
    private var exportTaskId: String?
    
    // MARK: - Initialization
    
    /// Initialize the export helper
    /// - Parameters:
    ///   - fileAccess: The file access instance to use for decryption
    ///   - media: Array of encrypted media items to export
    ///   - taskManager: The background task manager for tracking export progress
    public init(
        fileAccess: FileAccess,
        media: [InteractableMedia<EncryptedMedia>],
        taskManager: BackgroundTaskManager = .shared
    ) {
        self.fileAccess = fileAccess
        self.media = media
        self.taskManager = taskManager
    }
    
    // MARK: - Public Methods
    
    /// Export the selected media to a password-protected zip file
    /// - Parameters:
    ///   - password: The password to protect the zip file with (AES encryption)
    ///   - progress: Progress callback reporting current operation status
    /// - Returns: URL to the generated zip file in the temp export directory
    @MainActor
    public func exportToZip(
        password: String,
        progress: @escaping (ZipExportProgress) -> Void
    ) async throws -> URL {
        // Validate inputs
        guard !media.isEmpty else {
            throw ZipExportError.noMediaToExport
        }
        
        guard !password.isEmpty else {
            throw ZipExportError.emptyPassword
        }
        
        // Create and register the export task
        let task = createAndRegisterTask()
        exportTaskId = task.id
        
        // Start background task to prevent cleanup during export
        startBackgroundTask()
        
        do {
            // Create export directory if needed
            try createExportDirectoryIfNeeded()
            
            // Decrypt all media to temp directory
            let decryptedURLs = try await decryptMedia(progress: progress)
            
            // Check if background time expired
            if backgroundTimeExpired {
                throw ZipExportError.backgroundTimeExpired
            }
            
            guard !decryptedURLs.isEmpty else {
                throw ZipExportError.decryptionFailed("No files were successfully decrypted")
            }
            
            // Create password-protected zip
            let zipURL = try createPasswordProtectedZip(
                from: decryptedURLs,
                password: password,
                progress: progress
            )
            
            // Check if background time expired
            if backgroundTimeExpired {
                throw ZipExportError.backgroundTimeExpired
            }
            
            progress(.completed)
            
            // Finalize task as completed
            await finalizeTaskCompleted()
            endBackgroundTask()
            
            return zipURL
        } catch {
            // Finalize task as failed
            await finalizeTaskFailed(error: error)
            endBackgroundTask()
            throw error
        }
    }
    
    /// Cancels the export operation
    @MainActor
    public func cancelExport() {
        printDebug("Cancelling export")
        if let taskId = exportTaskId {
            taskManager.cancelTask(taskId: taskId)
        }
        endBackgroundTask()
    }
    
    // MARK: - Private Methods
    
    /// Creates the export directory if it doesn't exist
    private func createExportDirectoryIfNeeded() throws {
        let exportDir = URL.tempExportDirectory
        
        if !FileManager.default.fileExists(atPath: exportDir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: exportDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                printDebug("Created export directory at: \(exportDir.path)")
            } catch {
                throw ZipExportError.directoryCreationFailed(error.localizedDescription)
            }
        }
    }
    
    /// Decrypts all media items to the temp directory
    private func decryptMedia(
        progress: @escaping (ZipExportProgress) -> Void
    ) async throws -> [URL] {
        var decryptedURLs: [URL] = []
        let totalMedia = media.count
        var currentMediaIndex = 0
        
        let progressLock = NSLock()
        
        printDebug("Starting decryption of \(totalMedia) media items")
        printDebug("FileAccess type: \(type(of: fileAccess))")
        
        for mediaItem in media {
            // Check if background time expired before processing each item
            if backgroundTimeExpired {
                printDebug("Background time expired - stopping decryption")
                throw ZipExportError.backgroundTimeExpired
            }
            
            currentMediaIndex += 1
            let currentIndex = currentMediaIndex
            
            printDebug("Processing media item \(currentIndex)/\(totalMedia)")
            printDebug("  - Media ID: \(mediaItem.id)")
            printDebug("  - Media type: \(mediaItem.mediaType)")
            printDebug("  - Underlying media count: \(mediaItem.underlyingMedia.count)")
            for (idx, underlying) in mediaItem.underlyingMedia.enumerated() {
                printDebug("  - Underlying[\(idx)]: id=\(underlying.id), type=\(underlying.mediaType)")
                if case .url(let url) = underlying.source {
                    printDebug("    - URL: \(url.path)")
                } else if case .data(let data) = underlying.source {
                    printDebug("    - Data: \(data.count) bytes")
                }
            }
            
            do {
                printDebug("  - Calling loadMediaToURLs...")
                let urls = try await fileAccess.loadMediaToURLs(media: mediaItem) { [self] status in
                    progressLock.lock()
                    defer { progressLock.unlock() }
                    
                    switch status {
                    case .downloading(let percent):
                        self.printDebug("  - Downloading: \(Int(percent * 100))%")
                        let baseProgress = Double(currentIndex - 1) / Double(totalMedia)
                        let itemProgress = percent / Double(totalMedia)
                        let overallPercent = min(baseProgress + itemProgress, 1.0)
                        progress(.decrypting(current: currentIndex, total: totalMedia, percent: overallPercent))
                        // Update task manager progress
                        Task { @MainActor in
                            self.updateTaskProgress(current: currentIndex, total: totalMedia, progress: overallPercent)
                        }
                    case .decrypting(let percent):
                        self.printDebug("  - Decrypting: \(Int(percent * 100))%")
                        let baseProgress = Double(currentIndex - 1) / Double(totalMedia)
                        let itemProgress = percent / Double(totalMedia)
                        let overallPercent = min(baseProgress + itemProgress, 1.0)
                        progress(.decrypting(current: currentIndex, total: totalMedia, percent: overallPercent))
                        // Update task manager progress
                        Task { @MainActor in
                            self.updateTaskProgress(current: currentIndex, total: totalMedia, progress: overallPercent)
                        }
                    case .loaded:
                        self.printDebug("  - Status: Loaded")
                    case .notLoaded:
                        self.printDebug("  - Status: Not loaded")
                    }
                }
                printDebug("  - Successfully got \(urls.count) URLs")
                for (idx, url) in urls.enumerated() {
                    printDebug("    - URL[\(idx)]: \(url.lastPathComponent)")
                }
                decryptedURLs.append(contentsOf: urls)
                printDebug("Decrypted media item \(currentIndex)/\(totalMedia) successfully")
            } catch {
                printDebug("ERROR decrypting media item \(currentIndex): \(error)")
                printDebug("  - Error type: \(type(of: error))")
                printDebug("  - Localized: \(error.localizedDescription)")
                throw ZipExportError.decryptionFailed(error.localizedDescription)
            }
        }
        
        printDebug("Decryption complete. Total URLs: \(decryptedURLs.count)")
        return decryptedURLs
    }
    
    /// Creates a password-protected zip file from the decrypted URLs
    private func createPasswordProtectedZip(
        from urls: [URL],
        password: String,
        progress: @escaping (ZipExportProgress) -> Void
    ) throws -> URL {
        // Generate unique export name and paths
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let exportName = "encamera-export-\(timestamp)"
        let zipFilename = "\(exportName).zip"
        let zipPath = URL.tempExportDirectory.appendingPathComponent(zipFilename)
        
        // Create a subdirectory with the export name to hold the files
        let contentDirectory = URL.tempExportDirectory.appendingPathComponent(exportName)
        
        // Clean up any existing directory or zip
        if FileManager.default.fileExists(atPath: contentDirectory.path) {
            try? FileManager.default.removeItem(at: contentDirectory)
        }
        if FileManager.default.fileExists(atPath: zipPath.path) {
            try? FileManager.default.removeItem(at: zipPath)
        }
        
        // Create the content directory
        do {
            try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
            printDebug("Created content directory: \(contentDirectory.path)")
        } catch {
            throw ZipExportError.directoryCreationFailed(error.localizedDescription)
        }
        
        // Copy files into the content directory
        for url in urls {
            let destinationURL = contentDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: destinationURL)
                printDebug("Copied \(url.lastPathComponent) to content directory")
            } catch {
                printDebug("Failed to copy \(url.lastPathComponent): \(error)")
                throw ZipExportError.zipCreationFailed("Failed to copy file: \(error.localizedDescription)")
            }
        }
        
        printDebug("Creating zip at: \(zipPath.path)")
        printDebug("Content directory: \(contentDirectory.path)")
        printDebug("Files to include: \(urls.map { $0.lastPathComponent })")
        
        // Create the password-protected zip using ZipArchive with keepParentDirectory
        // This will create a zip where all files are inside a folder named "encamera-export-..."
        let success = SSZipArchive.createZipFile(
            atPath: zipPath.path,
            withContentsOfDirectory: contentDirectory.path,
            keepParentDirectory: true,
            withPassword: password
        )
        
        // Clean up the content directory after zipping
        try? FileManager.default.removeItem(at: contentDirectory)
        
        guard success else {
            throw ZipExportError.zipCreationFailed("ZipArchive failed to create the zip file")
        }
        
        // Verify the zip was created
        guard FileManager.default.fileExists(atPath: zipPath.path) else {
            throw ZipExportError.zipCreationFailed("Zip file was not created at expected path")
        }
        
        printDebug("Successfully created password-protected zip at: \(zipPath.path)")
        progress(.compressing(percent: 1.0))
        
        return zipPath
    }
    
    // MARK: - Task Management
    
    /// Creates and registers an export task with BackgroundTaskManager
    @MainActor
    private func createAndRegisterTask() -> ExportTask {
        let task = ExportTask(mediaToExport: media)
        taskManager.addTask(task)
        taskManager.markTaskRunning(taskId: task.id)
        
        // Register cancellation handler
        taskManager.registerCancellationHandler(for: task.id) { [weak self] in
            self?.printDebug("Cancellation handler invoked for export task")
            self?.backgroundTimeExpired = true
        }
        
        printDebug("Created export task with ID: \(task.id) for \(media.count) items")
        return task
    }
    
    /// Updates the progress in BackgroundTaskManager
    @MainActor
    private func updateTaskProgress(current: Int, total: Int, progress: Double) {
        guard let taskId = exportTaskId else { return }
        
        let progressUpdate = ImportProgressUpdate(
            taskId: taskId,
            currentFileIndex: current,
            totalFiles: total,
            currentFileProgress: progress,
            overallProgress: progress,
            currentFileName: nil,
            state: .running,
            estimatedTimeRemaining: nil
        )
        
        taskManager.updateTaskProgress(taskId: taskId, progress: progressUpdate)
    }
    
    /// Finalizes the task as completed
    @MainActor
    private func finalizeTaskCompleted() async {
        guard let taskId = exportTaskId else { return }
        taskManager.finalizeTaskCompleted(taskId: taskId, totalItems: media.count)
        taskManager.unregisterCancellationHandler(for: taskId)
        printDebug("Export task completed: \(taskId)")
    }
    
    /// Finalizes the task as failed
    @MainActor
    private func finalizeTaskFailed(error: Error) async {
        guard let taskId = exportTaskId else { return }
        taskManager.finalizeTaskFailed(taskId: taskId, error: error)
        taskManager.unregisterCancellationHandler(for: taskId)
        printDebug("Export task failed: \(taskId) - \(error)")
    }
    
    // MARK: - Background Task Management
    
    @MainActor
    private func startBackgroundTask() {
        printDebug("Starting UIBackgroundTask for export")
        endBackgroundTask()
        backgroundTimeExpired = false
        
        activeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ZipExport") { [weak self] in
            self?.printDebug("UIBackgroundTask expiration handler called - background time limit reached")
            Task { @MainActor in
                self?.backgroundTimeExpired = true
                // Mark the task as failed due to background time expiration
                if let taskId = self?.exportTaskId {
                    self?.taskManager.finalizeTaskFailed(taskId: taskId, error: ZipExportError.backgroundTimeExpired)
                }
            }
            self?.endBackgroundTask()
        }
        
        if activeBackgroundTask == .invalid {
            printDebug("Failed to start UIBackgroundTask - got invalid identifier")
        } else {
            printDebug("UIBackgroundTask started with identifier: \(activeBackgroundTask.rawValue)")
        }
    }
    
    @MainActor
    private func endBackgroundTask() {
        if activeBackgroundTask != .invalid {
            printDebug("Ending UIBackgroundTask with identifier: \(activeBackgroundTask.rawValue)")
            UIApplication.shared.endBackgroundTask(activeBackgroundTask)
            activeBackgroundTask = .invalid
        }
    }
    
    // MARK: - Cleanup
    
    /// Cleans up the export directory
    public static func cleanupExportDirectory() {
        let exportDir = URL.tempExportDirectory
        
        guard FileManager.default.fileExists(atPath: exportDir.path) else {
            return
        }
        
        do {
            try FileManager.default.removeItem(at: exportDir)
            debugPrint("Cleaned up export directory")
        } catch {
            debugPrint("Failed to cleanup export directory: \(error)")
        }
    }
}

