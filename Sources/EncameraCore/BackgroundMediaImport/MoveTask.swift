//
//  MoveTask.swift
//  EncameraCore
//
//  Created by Alexander Freas on 10.12.25.
//

import Foundation

/// Represents a task for moving media files between albums
public struct MoveTask: BackgroundFileTask {
    public let id: String
    public let taskType: FileTaskType = .moveMedia
    public let mediaToMove: [InteractableMedia<EncryptedMedia>]
    public let sourceAlbumId: String
    public let targetAlbumId: String
    public let targetAlbumName: String
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: FileTaskState {
        progress.state
    }
    public let assetIdentifiers: [String]
    
    /// The number of media items to move
    public var totalMediaCount: Int {
        mediaToMove.count
    }
    
    public init(
        id: String = UUID().uuidString,
        mediaToMove: [InteractableMedia<EncryptedMedia>],
        sourceAlbumId: String,
        targetAlbumId: String,
        targetAlbumName: String
    ) {
        self.id = id
        self.mediaToMove = mediaToMove
        self.sourceAlbumId = sourceAlbumId
        self.targetAlbumId = targetAlbumId
        self.targetAlbumName = targetAlbumName
        self.createdAt = Date()
        self.assetIdentifiers = []
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: mediaToMove.count,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }
    
    public static func == (lhs: MoveTask, rhs: MoveTask) -> Bool {
        return lhs.id == rhs.id
    }
}
