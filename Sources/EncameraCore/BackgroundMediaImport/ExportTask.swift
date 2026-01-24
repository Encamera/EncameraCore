//
//  ExportTask.swift
//  EncameraCore
//
//  Created by Alexander Freas on 03.01.26.
//

import Foundation

/// Represents a task for exporting encrypted media to a password-protected zip file
public struct ExportTask: BackgroundFileTask {
    public let id: String
    public let taskType: FileTaskType = .exportMedia
    public let mediaToExport: [InteractableMedia<EncryptedMedia>]
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: FileTaskState {
        progress.state
    }
    public let assetIdentifiers: [String]
    
    /// The number of media items to export
    public var totalMediaCount: Int {
        mediaToExport.count
    }
    
    public init(
        id: String = UUID().uuidString,
        mediaToExport: [InteractableMedia<EncryptedMedia>]
    ) {
        self.id = id
        self.mediaToExport = mediaToExport
        self.createdAt = Date()
        self.assetIdentifiers = []
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: mediaToExport.count,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }
    
    public static func == (lhs: ExportTask, rhs: ExportTask) -> Bool {
        return lhs.id == rhs.id
    }
}

