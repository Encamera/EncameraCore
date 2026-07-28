//
//  MigrationTask.swift
//  EncameraCore
//
//  A background task representing a local -> CloudKit album migration, so the
//  existing floating progress UI (CircularProgressView + ETA + keep-screen-awake)
//  surfaces it for free. The durable state lives in the `MigrationPlan` checkpoint;
//  this is only the in-memory mirror the progress UI binds to.
//  See plans/cloudkit-migration/12-local-to-cloudkit-migration.md.
//

import Foundation

public struct MigrationTask: BackgroundFileTask {

    /// Which way the storage move runs, so terminal pill copy can say "Moved to
    /// iCloud" vs "Moved to this device" instead of always claiming the former.
    public enum Direction: Sendable {
        case toCloudKit
        case toLocal
    }

    public let id: String
    public let taskType: FileTaskType = .migrateStorage
    public let albumName: String
    /// The source album's id (still `.local`/`.icloud` until the migration finishes).
    public let albumId: String
    public let direction: Direction
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: FileTaskState { progress.state }
    public let assetIdentifiers: [String] = []

    public init(id: String = UUID().uuidString,
                albumName: String,
                albumId: String,
                totalItems: Int,
                direction: Direction = .toCloudKit) {
        self.id = id
        self.albumName = albumName
        self.albumId = albumId
        self.direction = direction
        self.createdAt = Date()
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: totalItems,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }

    public static func == (lhs: MigrationTask, rhs: MigrationTask) -> Bool {
        lhs.id == rhs.id
    }
}
