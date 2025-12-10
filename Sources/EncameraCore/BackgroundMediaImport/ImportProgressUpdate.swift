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
    
    public init(taskId: String, currentFileIndex: Int, totalFiles: Int, currentFileProgress: Double, overallProgress: Double, currentFileName: String?, state: FileTaskState, estimatedTimeRemaining: TimeInterval?) {
        self.taskId = taskId
        self.currentFileIndex = currentFileIndex
        self.totalFiles = totalFiles
        self.currentFileProgress = currentFileProgress
        self.overallProgress = overallProgress
        self.currentFileName = currentFileName
        self.state = state
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

