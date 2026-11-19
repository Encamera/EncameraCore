//
//  ImportPipeline.swift
//  EncameraCore
//
//  The per-item import work, run off the main thread. `MediaImportHandler`
//  stays on the main actor as the coordinator: it registers the task, handles
//  cancel, finalizes and records history. Everything per item (free-space
//  reads, loading, saving, temp-file deletes, logging) runs here.
//

import Foundation

// MARK: - Progress Sink

/// Feeds item progress into an `ImportProgressAggregator` on the caller's
/// thread, and hops to the main actor only for a change the aggregator says to
/// publish. Encryptors report thousands of times per file, so throttling before
/// the hop keeps the main thread to about ten jobs a second plus one per item
/// boundary.
///
/// `publish` reads the aggregator's current values when it runs. Hops can run
/// out of order, but the total never goes down, so a late hop shows a newer
/// value, never an older one. A hop carries its own item index, though, so a
/// report hop that runs after its item finished publishes nothing: the item
/// boundary has already been published, and a later item may be the current
/// one by then. Once `close()` has run on main, no hop publishes, so a hop
/// still queued at the end of the run can't overwrite the final state.
final class ImportProgressSink: @unchecked Sendable {
    typealias Publish = @MainActor @Sendable (_ item: Int, _ mediaId: String?, _ aggregator: ImportProgressAggregator) -> Void

    let aggregator: ImportProgressAggregator
    private let publish: Publish
    /// Called, on the reporting thread, each time progress is about to hop to
    /// the main actor.
    private let onMainHop: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var isClosed = false

    init(aggregator: ImportProgressAggregator, onMainHop: (@Sendable () -> Void)? = nil, publish: @escaping Publish) {
        self.aggregator = aggregator
        self.onMainHop = onMainHop
        self.publish = publish
    }

    /// Records an item's progress from any thread. Hops to main only when the
    /// aggregator says the change is worth publishing.
    func report(item index: Int, fraction: Double, mediaId: String?) {
        guard aggregator.update(item: index, fraction: fraction) else { return }
        onMainHop?()
        Task { @MainActor in
            self.publishIfOpen(item: index, mediaId: mediaId, isItemBoundary: false)
        }
    }

    /// Counts an item as done, imported or failed, and publishes the new total.
    /// Waits for the publish, so every item boundary reaches main before the
    /// run ends.
    func finish(item index: Int) async {
        guard aggregator.finish(item: index) else { return }
        onMainHop?()
        await MainActor.run {
            self.publishIfOpen(item: index, mediaId: nil, isItemBoundary: true)
        }
    }

    /// Stops publishing. Call on main before finalizing the task.
    @MainActor
    func close() {
        lock.withLock { isClosed = true }
    }

    /// `isItemBoundary` is true for the publish that marks the item done, and
    /// false for a progress report, which is dropped once its item is done.
    @MainActor
    private func publishIfOpen(item index: Int, mediaId: String?, isItemBoundary: Bool) {
        guard !lock.withLock({ isClosed }) else { return }
        guard isItemBoundary || !aggregator.hasFinishedItem(at: index) else { return }
        publish(index, mediaId, aggregator)
    }
}

// MARK: - Pipeline

/// Runs one import's items. Not isolated to any actor, so its work runs off the
/// main thread; the only main-thread hops are the task-still-exists check per
/// item and progress publishes through the sink.
///
/// A struct rather than an actor: the batch path imports three groups at once,
/// and an actor would run them one at a time between awaits. Shared mutable
/// state lives in the lock-guarded aggregator.
struct ImportPipeline: Sendable, DebugPrintable {
    /// Share of a picked item's progress spent loading it out of the photo
    /// library; the rest is the save. Loading dominates for anything iCloud has
    /// to download, and is near-instant for what is already on the device.
    static let streamingLoadShare = 0.5

    /// What a streaming run brought in.
    struct StreamingOutcome: Sendable {
        let summary: ImportResultSummary
        let assetIdentifiers: [String]
        let mediaIdsByAssetId: [String: String]
    }

    let mediaLoader: ImportMediaLoading
    let saveOperation: ImportSaveOperation
    let freeSpace: DeviceFreeSpaceProviding
    /// Whether the task is still in `BackgroundTaskManager`. A removed task
    /// stops the run after its current item.
    let isTaskActive: @MainActor @Sendable () -> Bool
    let canDeleteTempFiles: Bool
    /// The test hooks as they stood when the run started.
    let testHooks: MediaImportTestHooks.Snapshot
    let sink: ImportProgressSink

    /// How many media groups the batch path imports at once.
    private static let batchSize = 3

    /// Outcome of importing a single media group within a batch.
    private enum MediaGroupOutcome: Sendable {
        case success
        case failure(ImportItemFailure)
    }

    /// Outcome of loading and importing one picked item.
    private enum PickedItemOutcome {
        case imported(LoadedMediaItem)
        case failed(ImportItemFailure)
        case cancelled
    }

    /// Running counts for one import run, shared by the batch and streaming paths.
    private struct RunTally {
        private(set) var successCount = 0
        private(set) var failedItems: [ImportItemFailure] = []
        /// True once the run has to stop because the disk is full: before items
        /// that won't fit, or after a write that ran out of space.
        private(set) var stoppedForSpace = false

        mutating func recordSuccess() {
            successCount += 1
        }

        /// Records a failed item. A failure caused by a full disk also stops the run.
        mutating func recordFailure(_ failure: ImportItemFailure) {
            failedItems.append(failure)
            if ImportSkipReason.isOutOfSpace(failure.error) {
                stoppedForSpace = true
            }
        }

        mutating func stopForInsufficientDiskSpace() {
            stoppedForSpace = true
        }

        func makeSummary(notAttemptedCount: Int) -> ImportResultSummary {
            ImportResultSummary(
                success: successCount,
                failure: failedItems.count,
                failedItems: failedItems,
                stoppedForSpace: stoppedForSpace,
                notAttemptedCount: notAttemptedCount
            )
        }
    }

    // MARK: Batch

    /// Imports preloaded media three groups at a time.
    ///
    /// Fault-tolerant per media group: a group that fails to import is recorded and
    /// skipped instead of aborting the whole task, mirroring the streaming path's
    /// per-item catch. Cancellation still propagates so a cancel halts the import.
    /// Stops before a batch that won't fit, and after a batch in which a write
    /// ran out of space.
    func runBatch(task: ImportTask, media: [CleartextMedia], fileAccess: FileAccess, plannedSizes: [Int64?]?) async throws -> ImportResultSummary {
        printDebug("Performing batch import for task: \(task.id)")

        let mediaGroups = groupMediaById(media)
        let totalGroups = mediaGroups.count
        printDebug("Grouped \(media.count) media items into \(totalGroups) groups (live photos count as 1)")

        let batches = mediaGroups.chunked(into: Self.batchSize)
        printDebug("Processing \(batches.count) batches of size \(Self.batchSize)")

        var tally = RunTally()
        var processedGroups = 0

        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()

            let batchStart = batchIndex * Self.batchSize
            let groupIndexes = batchStart..<batchStart + batch.count
            let batchName = "batch \(batchIndex + 1)/\(batches.count)"
            guard await canStartImporting(unitNamed: batchName, at: groupIndexes, plannedSizes: plannedSizes, taskId: task.id, tally: &tally) else {
                break
            }

            printDebug("Processing \(batchName) with \(batch.count) media groups")
            let outcomes = try await importMediaGroupsConcurrently(batch, startingAt: batchStart, totalGroups: totalGroups, fileAccess: fileAccess)
            for outcome in outcomes {
                switch outcome {
                case .success:
                    tally.recordSuccess()
                case .failure(let failure):
                    tally.recordFailure(failure)
                }
            }

            for index in groupIndexes {
                await sink.finish(item: index)
            }
            processedGroups += batch.count
            printDebug("Completed \(batchName), total processed: \(processedGroups)/\(totalGroups)")

            if tally.stoppedForSpace {
                printDebug("A write ran out of space - stopping import")
                break
            }
        }

        printDebug("Batch import completed for task: \(task.id) - success: \(tally.successCount), failed: \(tally.failedItems.count)")
        return tally.makeSummary(notAttemptedCount: totalGroups - processedGroups)
    }

    /// Imports one batch's media groups at the same time and returns an outcome
    /// for each. Throws only when the import is cancelled.
    private func importMediaGroupsConcurrently(
        _ batch: [[CleartextMedia]],
        startingAt batchStart: Int,
        totalGroups: Int,
        fileAccess: FileAccess
    ) async throws -> [MediaGroupOutcome] {
        try await withThrowingTaskGroup(of: MediaGroupOutcome.self) { group in
            for (offset, mediaGroup) in batch.enumerated() {
                group.addTask {
                    try await self.importMediaGroupCatchingFailure(
                        mediaGroup,
                        groupIndex: batchStart + offset,
                        totalGroups: totalGroups,
                        fileAccess: fileAccess
                    )
                }
            }

            var outcomes: [MediaGroupOutcome] = []
            for try await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    /// Imports one media group, turning any error but a cancel into a recorded
    /// failure so the rest of the batch carries on.
    private func importMediaGroupCatchingFailure(
        _ mediaGroup: [CleartextMedia],
        groupIndex: Int,
        totalGroups: Int,
        fileAccess: FileAccess
    ) async throws -> MediaGroupOutcome {
        let mediaId = mediaGroup.first?.id ?? "unknown"
        do {
            try await processMediaGroup(
                mediaGroup: mediaGroup,
                fileAccess: fileAccess,
                groupIndex: groupIndex,
                totalGroups: totalGroups
            )
            return .success
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            printDebug("Skipping media \(mediaId): \(error)")
            return .failure(ImportItemFailure(id: mediaId, error: error))
        }
    }

    // MARK: Streaming

    /// Loads and imports picked items one at a time.
    ///
    /// Stops before an item that won't fit, and after an item whose load or
    /// write ran out of space, so nothing more is downloaded onto a full disk.
    /// Never throws: a failed item is recorded in the summary, and a cancel
    /// ends the loop and returns what was imported up to then.
    func runStreaming(task: ImportTask, results: [MediaSelectionResult], fileAccess: FileAccess, plannedSizes: [Int64?]?) async -> StreamingOutcome {
        printDebug("Performing streaming import for task: \(task.id) with \(results.count) results")

        var tally = RunTally()
        var attemptedCount = 0
        var assetIdentifiers: [String] = []
        var mediaIdsByAssetId: [String: String] = [:]

        for (index, result) in results.enumerated() {
            // Cancelling stops the loop but keeps what already landed: the caller
            // sees fewer processed items than requested and finalizes as cancelled
            // with these asset identifiers, which the import history needs to offer
            // deleting exactly the originals that made it in.
            if Task.isCancelled { break }

            let itemName = "item \(index + 1)/\(results.count)"
            guard await canStartImporting(unitNamed: itemName, at: index..<index + 1, plannedSizes: plannedSizes, taskId: task.id, tally: &tally) else {
                break
            }
            attemptedCount += 1

            printDebug("Processing \(itemName)")
            var stopAfterItem = false
            switch await loadAndImportPickedItem(result, at: index, named: itemName, fileAccess: fileAccess) {
            case .imported(let item):
                tally.recordSuccess()
                if let assetId = item.assetIdentifier {
                    assetIdentifiers.append(assetId)
                    if let mediaId = item.media.first?.id {
                        mediaIdsByAssetId[assetId] = mediaId
                    }
                }
            case .failed(let failure):
                tally.recordFailure(failure)
                if tally.stoppedForSpace {
                    printDebug("\(itemName) ran out of space - stopping import")
                    stopAfterItem = true
                }
            case .cancelled:
                stopAfterItem = true
            }

            if !Task.isCancelled {
                await sink.finish(item: index)
            }
            if stopAfterItem { break }
        }

        printDebug("Streaming import complete - imported: \(tally.successCount)/\(results.count), failed: \(tally.failedItems.count), asset ids: \(assetIdentifiers.count)")
        let summary = tally.makeSummary(notAttemptedCount: tally.stoppedForSpace ? results.count - attemptedCount : 0)
        return StreamingOutcome(summary: summary, assetIdentifiers: assetIdentifiers, mediaIdsByAssetId: mediaIdsByAssetId)
    }

    /// Loads one picked item out of the photo library and saves it, then
    /// deletes its temp files. A load or save that ran out of space also
    /// deletes them, since the run stops there and nothing will retry it.
    private func loadAndImportPickedItem(
        _ result: MediaSelectionResult,
        at index: Int,
        named itemName: String,
        fileAccess: FileAccess
    ) async -> PickedItemOutcome {
        var loaded: LoadedMediaItem?
        do {
            let item = try await mediaLoader.loadSingleMedia(from: result) { [sink] loadFraction in
                sink.report(item: index, fraction: loadFraction * Self.streamingLoadShare, mediaId: nil)
            }
            loaded = item

            try await importSingleItem(
                mediaGroup: item.media,
                metadata: item.metadata,
                fileAccess: fileAccess,
                groupIndex: index,
                saveStart: Self.streamingLoadShare
            )

            deleteTempFilesIfPermitted(for: item.media)
            printDebug("Successfully imported \(itemName)")
            return .imported(item)
        } catch is CancellationError {
            return .cancelled
        } catch {
            printDebug("Error processing \(itemName): \(error)")
            if let loaded, ImportSkipReason.isOutOfSpace(error) {
                deleteTempFilesIfPermitted(for: loaded.media)
            }
            return .failed(ImportItemFailure(id: loaded?.assetIdentifier ?? "\(index)", error: error))
        }
    }

    // MARK: Stop Checks

    /// Whether the run can go on to import the items at `indexes`. It can't
    /// once the task has been removed, or when the items won't fit on disk; the
    /// second case is recorded in `tally`. `unitName` names the items in the log.
    private func canStartImporting(
        unitNamed unitName: String,
        at indexes: Range<Int>,
        plannedSizes: [Int64?]?,
        taskId: String,
        tally: inout RunTally
    ) async -> Bool {
        guard await isTaskActive() else {
            printDebug("Import \(taskId) stopping: its task was removed from BackgroundTaskManager")
            return false
        }
        let itemSizes = indexes.map { plannedSize(at: $0, in: plannedSizes) }
        guard hasDiskSpaceFree(forItemSizes: itemSizes) else {
            printDebug("Not enough space for \(unitName) - stopping import")
            tally.stopForInsufficientDiskSpace()
            return false
        }
        return true
    }

    private func plannedSize(at index: Int, in plannedSizes: [Int64?]?) -> Int64? {
        guard let plannedSizes, plannedSizes.indices.contains(index) else { return nil }
        return plannedSizes[index]
    }

    /// Whether writing items of these sizes leaves the reserve untouched.
    /// Unknown sizes count as zero, so only the reserve is checked for them.
    private func hasDiskSpaceFree(forItemSizes sizes: [Int64?]) -> Bool {
        guard let free = freeSpace.availableBytesForImport() else { return true }
        let needed = sizes.compactMap { $0 }.reduce(Int64(0)) { $0 + ImportSpaceBudget.storedBytes(forItemOfSize: $1) }
        return free >= ImportSpaceBudget.reserveBytes + needed
    }

    // MARK: Media Processing

    /// Saves one item, mapping its save progress from `saveStart` to 1.
    private func importSingleItem(
        mediaGroup: [CleartextMedia],
        metadata: EncryptedFileMetadata? = nil,
        fileAccess: FileAccess,
        groupIndex: Int,
        saveStart: Double = 0.0
    ) async throws {
        try await testHooks.applyBeforeSavingItem(at: groupIndex)
        let mediaId = mediaGroup.first?.id ?? "unknown"
        let interactableMedia = try InteractableMedia(underlyingMedia: mediaGroup)

        try await saveMedia(
            interactableMedia,
            metadata: metadata,
            mediaGroup: mediaGroup,
            mediaId: mediaId,
            fileAccess: fileAccess,
            groupIndex: groupIndex,
            saveStart: saveStart
        )
    }

    /// Processes a group of CleartextMedia items as a single InteractableMedia.
    private func processMediaGroup(
        mediaGroup: [CleartextMedia],
        fileAccess: FileAccess,
        groupIndex: Int,
        totalGroups: Int
    ) async throws {
        let mediaId = mediaGroup.first?.id ?? "unknown"
        let isLivePhoto = mediaGroup.count > 1
        printDebug("Processing \(isLivePhoto ? "live photo" : "media") \(groupIndex + 1)/\(totalGroups): \(mediaId) (\(mediaGroup.count) component(s))")

        logSourceFileStatus(for: mediaGroup)

        var metadata: EncryptedFileMetadata?
        if MediaMetadataExtractor.isImportMetadataEnabled, let firstMedia = mediaGroup.first, let url = firstMedia.url {
            let extractor = MediaMetadataExtractor()
            metadata = await extractor.extractMetadata(from: url, mediaType: firstMedia.mediaType)
            if let originalFilename = firstMedia.originalFilename {
                metadata?.originalFilename = originalFilename
            }
        }

        try await importSingleItem(
            mediaGroup: mediaGroup,
            metadata: metadata,
            fileAccess: fileAccess,
            groupIndex: groupIndex
        )

        printDebug("Successfully saved \(isLivePhoto ? "live photo" : "media") \(groupIndex + 1)/\(totalGroups): \(mediaId)")
    }

    /// Saves the InteractableMedia to disk and reports progress. The save's own
    /// 0...1 maps onto the item's progress from `saveStart` to 1.
    private func saveMedia(
        _ interactableMedia: InteractableMedia<CleartextMedia>,
        metadata: EncryptedFileMetadata? = nil,
        mediaGroup: [CleartextMedia],
        mediaId: String,
        fileAccess: FileAccess,
        groupIndex: Int,
        saveStart: Double
    ) async throws {
        do {
            try await saveOperation(fileAccess, interactableMedia, metadata) { [sink] fileProgress in
                sink.report(item: groupIndex, fraction: saveStart + (1.0 - saveStart) * fileProgress, mediaId: mediaId)
            }
        } catch {
            logSaveError(error, mediaGroup: mediaGroup, mediaId: mediaId)
            throw error
        }
        await sink.finish(item: groupIndex)
    }

    // MARK: Helpers

    /// Groups CleartextMedia items by their ID so that live photo components are processed together.
    private func groupMediaById(_ media: [CleartextMedia]) -> [[CleartextMedia]] {
        var groups: [String: [CleartextMedia]] = [:]
        for item in media {
            groups[item.id, default: []].append(item)
        }
        var seen = Set<String>()
        return media.compactMap { item -> [CleartextMedia]? in
            guard !seen.contains(item.id) else { return nil }
            seen.insert(item.id)
            return groups[item.id]
        }
    }

    /// Logs source file status for debugging temp file issues.
    private func logSourceFileStatus(for mediaGroup: [CleartextMedia]) {
        for media in mediaGroup {
            guard case .url(let sourceURL) = media.source else { continue }

            let fileManager = FileManager.default
            let exists = fileManager.fileExists(atPath: sourceURL.path)
            printDebug("Source: \(sourceURL.lastPathComponent), exists: \(exists)")

            if !exists {
                printDebug("WARNING: Source file missing at \(sourceURL.path)")
            } else if sourceURL.path.contains("/tmp/") {
                printDebug("Note: File is in temp directory")
            }
        }
    }

    /// Logs detailed error information when save fails.
    private func logSaveError(_ error: Error, mediaGroup: [CleartextMedia], mediaId: String) {
        printDebug("Failed to save media \(mediaId): \(error)")

        if let nsError = error as NSError? {
            printDebug("Error domain: \(nsError.domain), code: \(nsError.code)")

            if nsError.domain == NSCocoaErrorDomain && nsError.code == 4 {
                printDebug("File not found - temp files may have been cleaned up")
                for media in mediaGroup {
                    if case .url(let url) = media.source {
                        printDebug("Post-error check - \(url.lastPathComponent) exists: \(FileManager.default.fileExists(atPath: url.path))")
                    }
                }
            }
        }
    }

    /// Deletes the given media's files from the temp media directory, when
    /// this run is allowed to delete temp files.
    private func deleteTempFilesIfPermitted(for media: [CleartextMedia]) {
        guard canDeleteTempFiles else { return }
        let tempDirPath = URL.tempMediaDirectory.path
        for item in media {
            guard case .url(let url) = item.source, url.path.hasPrefix(tempDirPath) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                printDebug("Deleted temp file: \(url.lastPathComponent)")
            } catch {
                printDebug("Failed to delete temp file \(url.lastPathComponent): \(error)")
            }
        }
    }
}
