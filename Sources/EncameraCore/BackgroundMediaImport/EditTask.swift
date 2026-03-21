//
//  EditTask.swift
//  EncameraCore
//

import Foundation

/// Represents a task for editing (rotating) encrypted media
public struct EditTask: BackgroundFileTask {
    public let id: String
    public let taskType: FileTaskType = .editMedia
    public let mediaToEdit: InteractableMedia<EncryptedMedia>
    public let rotationAngle: Int  // 90, 180, 270
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: FileTaskState {
        progress.state
    }
    public let assetIdentifiers: [String]

    public init(
        id: String = UUID().uuidString,
        mediaToEdit: InteractableMedia<EncryptedMedia>,
        rotationAngle: Int
    ) {
        self.id = id
        self.mediaToEdit = mediaToEdit
        self.rotationAngle = rotationAngle
        self.createdAt = Date()
        self.assetIdentifiers = []
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: 1,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }

    public static func == (lhs: EditTask, rhs: EditTask) -> Bool {
        return lhs.id == rhs.id
    }
}
