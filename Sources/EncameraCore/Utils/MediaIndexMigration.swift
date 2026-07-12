//
//  MediaIndexMigration.swift
//  EncameraCore
//
//  One-time startup migration that builds the per-album media index for albums
//  that pre-date the pagination feature. Idempotent — albums that already have
//  an index are skipped — and reports progress through `BackgroundTaskManager`.
//

import Foundation

public enum MediaIndexMigration {

    /// The build runs silently unless it is still going after this delay, at
    /// which point the progress card is surfaced. A migration that finishes
    /// faster than this never shows any UI.
    private static let progressSurfaceDelay: TimeInterval = 5

    /// Builds missing indexes for every album. Safe to call on each launch:
    /// albums that already have an index are skipped, and if none need building
    /// no work is done and no progress UI is shown.
    public static func run(albumManager: AlbumManaging) async {
        let albums = albumManager.fetchAlbumsFromFilesystem(includingHidden: true)
        let albumsNeedingIndex = albums.filter { !MediaIndexStore.hasIndex(for: $0) }
        guard !albumsNeedingIndex.isEmpty else {
            return
        }

        let reporter = await IndexBuildProgressReporter(totalAlbums: albumsNeedingIndex.count)

        // Surface the progress card only if the build outlasts the delay. A
        // fast build finishes first and cancels this before it ever registers
        // the task, so the user never sees the card flash by.
        let surfaceCard = Task {
            try? await Task.sleep(nanoseconds: UInt64(progressSurfaceDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await reporter.surface()
        }

        for (index, album) in albumsNeedingIndex.enumerated() {
            let access = await InteractableMediaFileAccess(for: album, albumManager: albumManager)
            await access.rebuildIndex { filesRead, totalFiles in
                await reporter.updateAlbumProgress(filesRead: filesRead, totalFiles: totalFiles)
            }
            await reporter.markAlbumCompleted(index: index)
        }

        surfaceCard.cancel()
        await reporter.finish()
    }
}

/// Bridges the index-build migration to `BackgroundTaskManager`. The task is
/// registered with the manager lazily — only once `surface()` is called — so a
/// fast migration produces no progress UI at all. All methods run on the main
/// actor, so `surface()` and `finish()` racing at the delay boundary resolve
/// deterministically: whichever runs first wins, and the loser is a no-op.
@MainActor
private final class IndexBuildProgressReporter {

    private enum State {
        /// Build in progress; the card has not been surfaced yet.
        case pending
        /// The card is visible and the task is registered with the manager.
        case surfaced
        /// The build is done; no further surfacing may happen.
        case finished
    }

    private let task: IndexBuildTask
    private let totalAlbums: Int
    private var completedAlbums = 0
    /// How far the album currently being indexed has progressed, 0...1.
    private var currentAlbumFraction: Double = 0
    private var state: State = .pending

    init(totalAlbums: Int) {
        self.totalAlbums = totalAlbums
        self.task = IndexBuildTask(albumCount: totalAlbums)
    }

    /// Registers the task with `BackgroundTaskManager`, making the progress
    /// card appear with whatever progress has accumulated so far. Does nothing
    /// if the build already finished before the surface delay elapsed.
    func surface() {
        guard state == .pending else { return }
        state = .surfaced
        BackgroundTaskManager.shared.addTask(task)
        BackgroundTaskManager.shared.markTaskRunning(taskId: task.id)
        BackgroundTaskManager.shared.updateTaskProgress(taskId: task.id, progress: progressUpdate())
    }

    /// Reports how far metadata reading for the current album has progressed.
    /// Combined with the completed-album count, this fills the bar smoothly
    /// even while a single large album is being indexed.
    func updateAlbumProgress(filesRead: Int, totalFiles: Int) {
        guard totalFiles > 0 else { return }
        currentAlbumFraction = min(1, Double(filesRead) / Double(totalFiles))
        pushProgress()
    }

    /// Records that one more album has been fully indexed.
    func markAlbumCompleted(index: Int) {
        completedAlbums = index + 1
        currentAlbumFraction = 0
        pushProgress()
    }

    /// Marks the build complete. If the card was surfaced it transitions to the
    /// completed state; otherwise it simply blocks any late `surface()` call so
    /// no orphaned task is left running in the manager.
    func finish() {
        switch state {
        case .surfaced:
            state = .finished
            BackgroundTaskManager.shared.finalizeTaskCompleted(taskId: task.id, totalItems: totalAlbums)
        case .pending:
            state = .finished
        case .finished:
            break
        }
    }

    /// Pushes the latest progress to the manager — a no-op until the card has
    /// been surfaced, so progress accrued early is held until `surface()` runs.
    private func pushProgress() {
        guard state == .surfaced else { return }
        BackgroundTaskManager.shared.updateTaskProgress(taskId: task.id, progress: progressUpdate())
    }

    /// Overall progress across all albums: completed albums plus the fraction
    /// of the album currently in flight.
    private var overallProgress: Double {
        guard totalAlbums > 0 else { return 1 }
        return min(1, (Double(completedAlbums) + currentAlbumFraction) / Double(totalAlbums))
    }

    private func progressUpdate() -> ImportProgressUpdate {
        ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: completedAlbums,
            totalFiles: totalAlbums,
            currentFileProgress: currentAlbumFraction,
            overallProgress: overallProgress,
            currentFileName: nil,
            state: .running,
            estimatedTimeRemaining: nil
        )
    }
}
