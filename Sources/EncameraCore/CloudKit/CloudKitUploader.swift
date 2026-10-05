//
//  CloudKitUploader.swift
//  EncameraCore
//
//  Takes captures from `CloudKitUploadQueue` to CloudKit, in the background,
//  retrying until they land.
//
//  The capture path no longer waits on CloudKit: `CloudKitFileAccess.saveSingle`
//  writes the photo to the device, puts it in the album, and hands it here. That
//  makes an upload failure a delay rather than a loss — which is the whole point,
//  because the previous arrangement (upload first, record locally only on
//  success) silently discarded a capture whenever CloudKit refused a record.
//
//  A queued item can only be uploaded through its album's coordinator, and
//  building one needs the album key the queue deliberately does not store. So the
//  uploader works with the coordinators that already exist for albums opened this
//  launch; anything else drains when its album is next opened.
//

import Foundation
import UIKit

public actor CloudKitUploader: DebugPrintable {

    public static let shared = CloudKitUploader()

    private let queue: CloudKitUploadQueue
    private let registry: CloudKitCoordinatorRegistry
    /// Nil means `CloudKitSyncStatusReporter.shared`, which can only be read on
    /// the main actor.
    private let statusReporter: CloudKitSyncStatusReporter?

    private var drainTask: Task<Void, Never>?
    /// Set when work arrives while a drain is running, so the running pass loops
    /// again instead of the new item waiting for an unrelated trigger.
    private var moreWorkArrived = false

    /// Earliest next attempt per record, so a retryable failure is not retried in
    /// a tight loop. In memory only: after a relaunch everything is eligible
    /// again, which is the behaviour we want on a fresh start.
    private var nextAttemptAfter: [String: Date] = [:]
    private var hasSwept = false

    public init(queue: CloudKitUploadQueue = .shared,
                registry: CloudKitCoordinatorRegistry = .shared,
                statusReporter: CloudKitSyncStatusReporter? = nil) {
        self.queue = queue
        self.registry = registry
        self.statusReporter = statusReporter
    }

    private func reporter() async -> CloudKitSyncStatusReporter {
        if let statusReporter { return statusReporter }
        return await CloudKitSyncStatusReporter.shared
    }

    // MARK: - Triggering

    /// Ask the uploader to make progress. Safe to call often and from anywhere —
    /// launch, foreground, a new capture, an album opening. Returns immediately;
    /// the work happens in the background.
    public func kick() {
        guard drainTask == nil else {
            moreWorkArrived = true
            return
        }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.runDrain()
        }
    }

    /// Drains and waits for the pass to finish. For tests and for callers that
    /// need to know the queue was given a real chance to empty.
    public func drainNow() async {
        kick()
        await drainTask?.value
    }

    /// Cancels the drain task and prevents new kicks from starting. Called
    /// during erase so no uploads race the zone delete.
    public func shutdown() {
        drainTask?.cancel()
        drainTask = nil
        rekickTask?.cancel()
        rekickTask = nil
        printDebug("shutdown ok")
    }

    private func runDrain() async {
        let backgroundTask = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "CloudKitUploadDrain") { [weak self] in
                guard let self else { return }
                Task { await self.handleBackgroundExpiration() }
            }
        }
        defer {
            if backgroundTask != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
            drainTask = nil
            scheduleRekickIfNeeded()
        }
        repeat {
            moreWorkArrived = false
            await onePass()
        } while moreWorkArrived && !Task.isCancelled
    }

    private func handleBackgroundExpiration() {
        printDebug("background time expired, cancelling drain")
        drainTask?.cancel()
    }

    /// Wakes the drain when the earliest in-flight backoff expires. Replaced on
    /// every drain, so at most one timer exists.
    private var rekickTask: Task<Void, Never>?

    private func scheduleRekickIfNeeded() {
        rekickTask?.cancel()
        rekickTask = nil
        let now = Date()
        guard let earliest = nextAttemptAfter.values.filter({ $0 > now }).min() else { return }
        let delay = earliest.timeIntervalSince(now)
        rekickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.kick()
        }
    }

    // MARK: - Draining

    private func onePass() async {
        if !hasSwept {
            hasSwept = true
            await queue.sweep()
            await queue.retryGivenUp()
        }
        let items = await queue.all().filter { !$0.hasGivenUp }
        guard !items.isEmpty else {
            await reportPassFinished()
            return
        }

        printDebug("drain start pending=\(items.count)")
        var uploaded = 0
        var deferredCount = 0

        for item in items {
            guard !Task.isCancelled else {
                printDebug("drain cancelled, stopping between items")
                break
            }
            await reporter().reportUploadProgress(completed: uploaded, total: items.count)
            if let notBefore = nextAttemptAfter[item.recordName], notBefore > Date() {
                deferredCount += 1
                continue
            }
            guard let coordinator = await registry.existingCoordinator(forAlbumID: item.albumID) else {
                deferredCount += 1
                continue
            }
            if await send(item, using: coordinator) { uploaded += 1 } else { deferredCount += 1 }
        }
        await reportPassFinished()
        printDebug("drain done uploaded=\(uploaded) deferred=\(deferredCount)")
    }

    /// Hands the UI the end of a pass: no upload is in flight, and whatever has
    /// given up is now the standing state. Reported even for an empty pass, so a
    /// backlog that drains — or one whose items are freed by `retryFailed` —
    /// clears the status bar rather than leaving a stale count on screen.
    private func reportPassFinished() async {
        let stalled = await queue.givenUp().count
        await reporter().reportUploadsFinished(stalled: stalled)
    }

    /// Returns true when the item reached CloudKit.
    private func send(_ item: CloudKitPendingUpload, using coordinator: CloudKitSyncCoordinator) async -> Bool {
        let previewURL = CloudKitStorageModel.previewURL(forMediaID: item.mediaID)
        let thumbURL = FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil
        let upload = await queue.rebuild(item, thumbURL: thumbURL)

        do {
            _ = try await coordinator.upload(upload, progress: { _ in }, alreadyVisibleLocally: true)
        } catch {
            guard await resolve(error, for: item, upload: upload, using: coordinator) else { return false }
        }

        // Only now is it safe to drop the durable copy: the bytes are in CloudKit
        // and in the blob cache — stored by `coordinator.upload`, or by
        // `adoptLandedUpload` for a record an earlier attempt committed.
        await queue.complete(recordName: item.recordName)
        nextAttemptAfter[item.recordName] = nil
        return true
    }

    /// Decides what a failed upload means for its queue item. Getting this wrong
    /// in the permanent direction strands a photo; getting it wrong in the
    /// retryable direction just means pointless attempts — so anything
    /// unrecognised is treated as retryable.
    ///
    /// `mapCKError` collapses a per-record error wrapped in `.partial`, which is
    /// how CloudKit reports a single-record save's conflict or quota failure.
    ///
    /// - Returns: true when the record turns out to be in CloudKit already, so
    ///   the caller completes the item.
    private func resolve(_ error: Error,
                         for item: CloudKitPendingUpload,
                         upload: CloudKitMediaUpload,
                         using coordinator: CloudKitSyncCoordinator) async -> Bool {
        switch mapCKError(error) {
        case .conflict:
            return await resolveConflict(error, for: item, upload: upload, using: coordinator)
        case .cancelled:
            await dropIfDeleted(item, error: error, using: coordinator)
            return false
        case .quotaExceeded:
            await queue.giveUp(recordName: item.recordName, reason: error)
            nextAttemptAfter[item.recordName] = nil
            return false
        case .accountUnavailable:
            await queue.recordAttempt(recordName: item.recordName, error: error)
            nextAttemptAfter[item.recordName] = Date().addingTimeInterval(300)
            return false
        case .retry(let after):
            await queue.recordAttempt(recordName: item.recordName, error: error)
            nextAttemptAfter[item.recordName] = Date().addingTimeInterval(after)
            return false
        default:
            await backOff(item, error: error)
            return false
        }
    }

    /// The save found a record under this name already. Almost always it is this
    /// item's own, committed by an earlier attempt that was killed before the
    /// queue cleared it — retrying would conflict forever. Adopt it when it
    /// matches; give up, keeping the file, when it is someone else's.
    private func resolveConflict(_ error: Error,
                                 for item: CloudKitPendingUpload,
                                 upload: CloudKitMediaUpload,
                                 using coordinator: CloudKitSyncCoordinator) async -> Bool {
        let match: CloudKitSyncCoordinator.LandedUploadMatch
        do {
            match = try await coordinator.adoptLandedUpload(upload, alreadyVisibleLocally: true)
        } catch {
            if case .cancelled = mapCKError(error) {
                await dropIfDeleted(item, error: error, using: coordinator)
            } else {
                await backOff(item, error: error)
            }
            return false
        }
        switch match {
        case .adopted:
            printDebug("conflict resolved recordName=\(item.recordName) — adopted the record an earlier attempt committed")
            return true
        case .missing:
            // Deleted since the save conflicted, so a plain retry can land.
            await backOff(item, error: error)
        case .notThisItem:
            printDebug("conflict unresolved recordName=\(item.recordName) — the record in CloudKit is not this item's")
            await queue.giveUp(recordName: item.recordName, reason: CloudKitUploadConflict(recordName: item.recordName))
            nextAttemptAfter[item.recordName] = nil
        }
        return false
    }

    /// An upload that landed after the item was deleted on this device: the
    /// coordinator has already reclaimed the fresh record, so the queue item —
    /// and its durable copy — goes too. Any other cancellation (the drain itself
    /// being stopped) is retried, because the photo is still wanted.
    private func dropIfDeleted(_ item: CloudKitPendingUpload,
                               error: Error,
                               using coordinator: CloudKitSyncCoordinator) async {
        if await coordinator.isDeletedOnThisDevice(recordName: item.recordName) {
            printDebug("cancelled recordName=\(item.recordName) — deleted on this device, dropping the queue item")
            await queue.cancel(recordName: item.recordName)
            nextAttemptAfter[item.recordName] = nil
        } else {
            await backOff(item, error: error)
        }
    }

    private func backOff(_ item: CloudKitPendingUpload, error: Error) async {
        await queue.recordAttempt(recordName: item.recordName, error: error)
        let attempts = min((await queue.all().first { $0.recordName == item.recordName })?.attempts ?? 1, 6)
        nextAttemptAfter[item.recordName] = Date().addingTimeInterval(pow(2, Double(attempts)))
    }

    // MARK: - Recovery

    /// Give previously-abandoned items another go — after the user frees up
    /// iCloud storage or signs back in. Clears the give-up flag and drains.
    public func retryFailed() async {
        await queue.retryGivenUp()
        nextAttemptAfter.removeAll()
        kick()
    }
}

/// Why an upload gave up on a conflict: CloudKit already holds a record under
/// this item's name, and its album or size says it is not this item.
public struct CloudKitUploadConflict: Error, CustomStringConvertible {
    public let recordName: String

    public var description: String {
        "A different record named \(recordName) is already in iCloud"
    }
}
