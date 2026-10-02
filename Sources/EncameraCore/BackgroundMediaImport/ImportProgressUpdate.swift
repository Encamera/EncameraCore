//
//  ImportProgressUpdate.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//

import Foundation
import BackgroundTasks
import Combine
import UIKit



public struct ImportProgressUpdate {
    public let taskId: String
    public let currentFileIndex: Int
    public let totalFiles: Int
    public let currentFileProgress: Double
    public let overallProgress: Double
    public let currentFileName: String?
    public var state: FileTaskState
    public let estimatedTimeRemaining: TimeInterval?
    /// Replaces the floating pill's "X of Y" line when the task is in a step that
    /// line cannot describe, such as a storage move removing its iCloud copies.
    public let statusText: String?

    public init(taskId: String, currentFileIndex: Int, totalFiles: Int, currentFileProgress: Double, overallProgress: Double, currentFileName: String?, state: FileTaskState, estimatedTimeRemaining: TimeInterval?, statusText: String? = nil) {
        self.taskId = taskId
        self.currentFileIndex = currentFileIndex
        self.totalFiles = totalFiles
        self.currentFileProgress = currentFileProgress
        self.overallProgress = overallProgress
        self.currentFileName = currentFileName
        self.state = state
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.statusText = statusText
    }
}

