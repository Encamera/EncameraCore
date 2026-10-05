//
//  CloudKitSyncStatusReporter.swift
//  EncameraCore
//
//  Carries CloudKit sync activity to the UI.
//

import Foundation
import Combine

/// What CloudKit sync is doing right now, as far as the user needs to know.
public enum CloudKitSyncActivity: Equatable, Sendable {

    /// Nothing in flight and nothing waiting.
    case idle
    /// Reconciling album existence and media indexes against the server.
    case checking
    /// Sending queued captures up. `total` is the size of the backlog this pass
    /// started with, so the fraction only ever moves forward within a pass.
    case uploading(completed: Int, total: Int)
    /// Uploads that have been abandoned and will not retry on their own.
    case stalled(count: Int)
    /// iCloud refused a write because the account's storage is full. `stalled` is
    /// how many uploads have given up, on that or anything else; 0 when only an
    /// album change could not be saved.
    case storageFull(stalled: Int)

    /// Progress through the current upload pass, or nil when there is no
    /// determinate work to show a bar for.
    public var fractionCompleted: Double? {
        guard case .uploading(let completed, let total) = self, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// What the bar says once everything settles, if anything.
public enum CloudKitSyncCompletion: Equatable, Sendable {
    case upToDate
    case unreachable
}

/// Publishes CloudKit sync activity for the home screen's status bar.
///
/// A shared singleton for the same reason as `LockedAlbumsReporter`: the
/// producers are actors owned by `EncameraApp` (`CloudKitAlbumsSync`) or global
/// singletons (`CloudKitUploader`), and the consumer is a view built
/// independently of both, so there is no common owner to inject through.
@MainActor
public final class CloudKitSyncStatusReporter: ObservableObject {

    public static let shared = CloudKitSyncStatusReporter()

    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var uploadsCompleted: Int = 0
    @Published public private(set) var uploadsTotal: Int = 0
    @Published public private(set) var stalledCount: Int = 0
    /// When the last successful reconcile finished, so the bar can say "synced
    /// just now" rather than simply vanishing. Nil until one succeeds this launch;
    /// a failed check never sets it.
    @Published public private(set) var lastSyncedAt: Date?
    /// Whether the most recent check could not reach iCloud (account gone or the
    /// album fetch failed). Cleared by the next successful check.
    @Published public private(set) var lastCheckFailed: Bool = false
    /// Whether the last upload pass gave up on an item because iCloud storage is
    /// full.
    @Published public private(set) var uploadsBlockedByFullStorage: Bool = false
    /// Whether the last successful check could not save an album change because
    /// iCloud storage is full.
    @Published public private(set) var albumSavesBlockedByFullStorage: Bool = false
    /// Whether an upload pass has finished this launch. Until one has, the stalled
    /// count and the storage-full flag are still the launch defaults, so a finished
    /// check cannot yet claim that iCloud is up to date.
    @Published public private(set) var hasFinishedUploadPass: Bool = false

    /// Pins the reported activity, ignoring every producer. Test-only: the real
    /// producers race any staged value — the empty upload drain that every launch
    /// kicks off reports "nothing pending" and would wipe a staged backlog before
    /// the bar could be read.
    @Published public private(set) var stagedActivity: CloudKitSyncActivity?

    /// Uploading outranks checking: the two overlap constantly (a reconcile ends
    /// by kicking the uploader) and a byte count is the more informative of the
    /// two. `storageFull` and `stalled` only show once nothing is moving, so a
    /// backlog that is draining is not also reported as stuck; storage full
    /// outranks stalled because it says what the user has to do.
    public var activity: CloudKitSyncActivity {
        if let stagedActivity {
            return stagedActivity
        }
        if uploadsTotal > 0 {
            return .uploading(completed: uploadsCompleted, total: uploadsTotal)
        }
        if isChecking {
            return .checking
        }
        if uploadsBlockedByFullStorage || albumSavesBlockedByFullStorage {
            return .storageFull(stalled: stalledCount)
        }
        if stalledCount > 0 {
            return .stalled(count: stalledCount)
        }
        return .idle
    }

    /// What an idle bar says, if anything: "Can't reach iCloud" after a failed
    /// check, and "iCloud is up to date" only once a check has succeeded and an
    /// upload pass has reported this launch.
    public var completion: CloudKitSyncCompletion? {
        if lastCheckFailed { return .unreachable }
        if lastSyncedAt != nil, hasFinishedUploadPass { return .upToDate }
        return nil
    }

    public init() {}

    /// See `stagedActivity`. Only ever called from `-StageSyncStatus` handling.
    public func stage(_ activity: CloudKitSyncActivity) {
        stagedActivity = activity
    }

    /// Called only once a reconcile has decided it really will talk to CloudKit
    /// — a pass that short-circuits on the feature flag, the credential wait, a
    /// missing iCloud account or the absence of any CloudKit album never
    /// reports, so it neither flashes the bar nor claims a sync.
    public func reportCheckStarted() {
        isChecking = true
    }

    /// Ends a check started with `reportCheckStarted()`. Only a check that
    /// succeeded stamps `lastSyncedAt`; a failed one is recorded in
    /// `lastCheckFailed` so the bar can say iCloud could not be reached.
    ///
    /// `storageFull` is whether an album change could not be saved because iCloud
    /// storage is full. A failed check learned nothing about that, so it leaves
    /// the previous answer standing.
    public func reportCheckFinished(succeeded: Bool, storageFull: Bool = false) {
        isChecking = false
        lastCheckFailed = !succeeded
        if succeeded {
            lastSyncedAt = Date()
            albumSavesBlockedByFullStorage = storageFull
        }
    }

    /// Progress within one upload drain pass.
    public func reportUploadProgress(completed: Int, total: Int) {
        uploadsCompleted = completed
        uploadsTotal = total
    }

    /// Ends an upload pass. `stalled` is the number of items that have given up
    /// and need the user to act before they move; `storageFull` is whether any of
    /// them gave up because iCloud storage is full.
    public func reportUploadsFinished(stalled: Int, storageFull: Bool = false) {
        uploadsCompleted = 0
        uploadsTotal = 0
        stalledCount = stalled
        uploadsBlockedByFullStorage = storageFull
        hasFinishedUploadPass = true
    }
}
