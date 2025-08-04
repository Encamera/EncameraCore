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



public struct ImportTask: Equatable {
    public let id: String
    public let media: [CleartextMedia]
    public let albumId: String
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: ImportTaskState {
        progress.state
    }
    public let assetIdentifiers: [String]
    
    public init(id: String = UUID().uuidString, media: [CleartextMedia], albumId: String, assetIdentifiers: [String] = []) {
        self.id = id
        self.media = media
        self.albumId = albumId
        self.createdAt = Date()
        self.assetIdentifiers = assetIdentifiers
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: media.count,
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
