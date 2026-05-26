//
//  IndexBuildTask.swift
//  EncameraCore
//
//  A background task that builds the per-album media index for albums that do
//  not have one yet — the one-time migration after the pagination feature
//  ships. It is not user-cancellable.
//

import Foundation

public struct IndexBuildTask: BackgroundFileTask {
    public let id: String
    public let taskType: FileTaskType = .buildIndex
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: FileTaskState {
        progress.state
    }
    public let assetIdentifiers: [String] = []
    /// The index migration registers no cancellation handler — `cancelTask`
    /// would mark the UI as cancelled while indexing continued silently.
    public let isCancelable: Bool = false

    /// - Parameter albumCount: The number of albums whose index will be built.
    public init(id: String = UUID().uuidString, albumCount: Int) {
        self.id = id
        self.createdAt = Date()
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: albumCount,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }

    public static func == (lhs: IndexBuildTask, rhs: IndexBuildTask) -> Bool {
        lhs.id == rhs.id
    }
}
