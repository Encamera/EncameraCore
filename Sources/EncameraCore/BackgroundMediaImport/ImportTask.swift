//
//  ImportTask.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//
import Foundation
import BackgroundTasks
import Combine
import UIKit

public enum ImportSource: String, Codable, CaseIterable {
    case photos = "photos"              // Media from photo library (can delete temp files)
    case files = "files"                // Media from file system (should not delete originals)
    case shareExtension = "shareExtension"  // Media from Share Extension (files in app group container)
    
    /// Whether temporary files can be safely deleted after import for this source type
    public var canDeleteTempFilesAfterImport: Bool {
        switch self {
        case .photos:
            return true  // Photo library imports copy to temp directory, safe to delete
        case .files:
            return false // File imports reference user's files, should not delete
        case .shareExtension:
            return true  // Share Extension files are in app group, safe to delete after import
        }
    }
}



public struct ImportTask: Equatable {
    public let id: String
    public let media: [CleartextMedia]
    public let albumId: String
    public let source: ImportSource
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: ImportTaskState {
        progress.state
    }
    public let assetIdentifiers: [String]
    /// Identifier for the user-initiated batch. Multiple ImportTasks with the same userBatchId
    /// were created from the same user selection (e.g., when selecting 20 photos from the photo picker,
    /// they may be split into multiple technical batches for processing efficiency).
    public let userBatchId: String?
    
    /// The number of unique media items (InteractableMedia) in this task.
    /// This groups live photo components (image + video with same ID) as a single item.
    public var uniqueMediaCount: Int {
        Set(media.map { $0.id }).count
    }
    
    public init(id: String = UUID().uuidString, media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = [], userBatchId: String? = nil) {
        self.id = id
        self.media = media
        self.albumId = albumId
        self.source = source
        self.createdAt = Date()
        self.assetIdentifiers = assetIdentifiers
        self.userBatchId = userBatchId
        // Calculate totalFiles from unique media IDs so live photos count as one item
        let uniqueMediaCount = Set(media.map { $0.id }).count
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: uniqueMediaCount,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }
    
    /// Creates an import task with a known total file count but no media yet.
    /// Used for streaming imports where items are loaded and imported one at a time.
    public init(id: String = UUID().uuidString, totalFiles: Int, albumId: String, source: ImportSource, userBatchId: String? = nil) {
        self.id = id
        self.media = []
        self.albumId = albumId
        self.source = source
        self.createdAt = Date()
        self.assetIdentifiers = []
        self.userBatchId = userBatchId
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: totalFiles,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }

    public static func ==(lhs: ImportTask, rhs: ImportTask) -> Bool {
        return lhs.id == rhs.id
    }
}
