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
    case photos = "photos"        // Media from photo library (can delete temp files)
    case files = "files"          // Media from file system (should not delete originals)
    
    /// Whether temporary files can be safely deleted after import for this source type
    public var canDeleteTempFilesAfterImport: Bool {
        switch self {
        case .photos:
            return true  // Photo library imports copy to temp directory, safe to delete
        case .files:
            return false // File imports reference user's files, should not delete
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
    
    public init(id: String = UUID().uuidString, media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = []) {
        self.id = id
        self.media = media
        self.albumId = albumId
        self.source = source
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
