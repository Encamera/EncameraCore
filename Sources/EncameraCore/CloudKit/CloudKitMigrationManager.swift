//
//  CloudKitMigrationManager.swift
//  EncameraCore
//
//  Drives a user-initiated, resumable, crash-safe migration of one album's media
//  from local (or iCloud-Drive) storage to CloudKit. The existing upload stack does
//  the transport (`CloudKitSyncCoordinator.upload` -> `CloudKitMediaStore.upload`);
//  this manager only sequences the work and checkpoints every step to disk so a
//  crash/kill/power-off resumes exactly where it left off (the durable `MigrationPlan`
//  is the source of truth, not CloudKit's deprecated long-lived ops).
//  See plans/cloudkit-migration/12-local-to-cloudkit-migration.md.
//

import Foundation
import Combine
import CloudKit

// MARK: - Observable state

public enum MigrationFailureReason: Equatable, Sendable {
    case quota                  // iCloud is full — recoverable once the user frees space
    case accountUnavailable     // not signed into iCloud
    /// The server rejected the record shape (`CKError.invalidArguments`, e.g.
    /// "Cannot create new type EncAlbum in production schema") — the CloudKit
    /// Production schema was never deployed for a type this build writes. Not
    /// recoverable on-device; see Documentation/cloudkit-schema-deploy.md.
    case schemaNotDeployed
    case other(String)
}

public enum MigrationState: Equatable, Sendable {
    case idle
    case planning
    case running
    case paused
    case completed
    case failed(MigrationFailureReason)
}

/// What the migration is doing to the current item, so the UI can say "Uploading"
/// rather than only showing a percentage. In-memory only: it is deliberately NOT
/// persisted to the checkpoint, where it would be a lie after a crash.
public enum MigrationPhase: String, Equatable, Sendable {
    case preparing
    case uploading
    case verifying
    case removingLocalCopy
    case retrying
    // The CloudKit -> local direction. The reverse move is not driven by this
    // engine, but it reports through the same `MigrationProgress` type so both
    // directions share one overlay.
    case downloading
    case removingRemoteCopy
}

/// A snapshot the UI binds to. Byte-weighted so a few large videos don't make a
/// mostly-done migration look stalled.
public struct MigrationProgress: Equatable, Sendable {
    public var fractionComplete: Double
    public var verifiedCount: Int
    public var totalCount: Int
    public var failedCount: Int
    public var totalBytes: Int64
    public var currentItemName: String?
    /// `nil` whenever the manager is idle, completed, failed, paused or cancelled.
    public var phase: MigrationPhase?

    public init(fractionComplete: Double = 0,
                verifiedCount: Int = 0,
                totalCount: Int = 0,
                failedCount: Int = 0,
                totalBytes: Int64 = 0,
                currentItemName: String? = nil,
                phase: MigrationPhase? = nil) {
        self.fractionComplete = fractionComplete
        self.verifiedCount = verifiedCount
        self.totalCount = totalCount
        self.failedCount = failedCount
        self.totalBytes = totalBytes
        self.currentItemName = currentItemName
        self.phase = phase
    }

    public static let idle = MigrationProgress()

    /// Derives a progress snapshot from a plan.
    public init(plan: MigrationPlan, currentItemName: String? = nil, phase: MigrationPhase? = nil) {
        self.init(fractionComplete: plan.fractionComplete,
                  verifiedCount: plan.verifiedCount,
                  totalCount: plan.items.count,
                  failedCount: plan.failedCount,
                  totalBytes: plan.totalBytes,
                  currentItemName: currentItemName,
                  phase: phase)
    }
}

/// A snapshot of the CloudKit -> local move, shaped so the app can feed the same
/// blocking overlay the forward migration drives. Counts are ciphertext
/// components (a Live Photo is two), matching what `exportCiphertext` copies.
public struct CloudToLocalMoveProgress: Equatable, Sendable {
    public let phase: MigrationPhase
    public let exportedCount: Int
    public let totalCount: Int

    public init(phase: MigrationPhase, exportedCount: Int, totalCount: Int) {
        self.phase = phase
        self.exportedCount = exportedCount
        self.totalCount = totalCount
    }
}

public enum MigrationError: Error, Equatable {
    /// Only `.local` albums can be migrated. `.icloud` is refused too: evicted
    /// files enumerate as placeholders with no materialized ciphertext, which the
    /// engine would terminally skip — see the guard in `plan(album:)`.
    case invalidSourceStorage(StorageType)
    /// The record did not appear in CloudKit after upload (verification failed); the
    /// source is never deleted in this case.
    case verificationFailed(recordName: String)
}

// MARK: - Manager

@MainActor
public final class CloudKitMigrationManager: ObservableObject, DebugPrintable {

    @Published public private(set) var state: MigrationState = .idle
    @Published public private(set) var progress: MigrationProgress = .idle

    /// Cooperative control checked between items so `pause`/`cancel` (also on the
    /// main actor) take effect at the next safe boundary without interrupting an
    /// item mid-transition.
    private enum RunControl { case running, pauseRequested, cancelRequested }
    private var control: RunControl = .running

    /// The store backing the run currently in flight, so `cancel()` can abort an
    /// in-progress upload immediately instead of waiting for it to finish.
    private var activeStore: CloudKitMediaStoring?

    /// The phase of the item currently being migrated. Held on the manager rather
    /// than written into `progress` at each transition because `run()` rebuilds
    /// `progress` wholesale before and after every item — a phase assigned inside
    /// `migrateItem` would be clobbered on the next loop turn. Every publish goes
    /// through `publishProgress`, which folds this in.
    private var currentPhase: MigrationPhase?

    /// The single funnel for `progress`. Nothing else may assign it, or the phase
    /// is silently dropped from that snapshot.
    private func publishProgress(_ plan: MigrationPlan, currentItemName: String? = nil) {
        progress = MigrationProgress(plan: plan, currentItemName: currentItemName, phase: currentPhase)
    }

    /// Sets the phase and republishes immediately. A phase that is only recorded and
    /// not published is invisible to the UI until the next item boundary, by which
    /// time it is already stale — so the transition and the publish stay together.
    private func setPhase(_ phase: MigrationPhase?,
                          plan: MigrationPlan,
                          currentItemName: String? = nil) {
        currentPhase = phase
        publishProgress(plan, currentItemName: currentItemName)
    }

    /// Max automatic retries for a `CloudKit retry(after:)` before an item is failed.
    private static let maxRetriesPerItem = 3

    private let albumManager: AlbumManaging
    /// Test seam: supplies the `CloudKitMediaStoring` for an album's token namespace.
    /// Production reads `CloudKitStoreProvider.makeStore` at call time (so a UI-test
    /// mock installed there still wins); tests inject a fixed mock here.
    private let storeFactoryOverride: (@Sendable (String) -> CloudKitMediaStoring)?

    public init(albumManager: AlbumManaging,
                storeFactory: (@Sendable (String) -> CloudKitMediaStoring)? = nil) {
        self.albumManager = albumManager
        self.storeFactoryOverride = storeFactory
    }

    private func makeStore(_ namespace: String) -> CloudKitMediaStoring {
        storeFactoryOverride?(namespace) ?? CloudKitStoreProvider.makeStore(namespace)
    }

    /// Test seam: overrides the album-id hash derivation (production uses
    /// `SyncedStoreEncryptionHandler.keyedHash`, whose failure modes — key-size
    /// violations — can't be reproduced with a key that still encrypts).
    var albumIDHashOverride: ((Album) -> String?)?

    private func deriveAlbumIDHash(for album: Album) -> String? {
        if let albumIDHashOverride { return albumIDHashOverride(album) }
        return SyncedStoreEncryptionHandler.keyedHash(album.name, keyBytes: album.key.keyBytes)
    }

    // MARK: - Planning

    /// Builds (or resumes) the migration plan for `album`: enumerate every encrypted
    /// component, assign a stable `mediaID` + deterministic CloudKit record name, and
    /// persist the plan encrypted to disk. Re-planning a partially-migrated album
    /// yields identical ids and preserves the state of items that already made
    /// progress, so nothing is re-uploaded or lost. Never touches a `.cloudKit` album.
    @discardableResult
    public func plan(album: Album) async throws -> MigrationPlan {
        // .local ONLY. An .icloud source is deliberately refused for now:
        // enumeration sees evicted files via their `.icloud` placeholders, but the
        // materialized path `driveURLForMedia` returns does not exist for them, so
        // the engine would terminally skip each one and then finalize — silently
        // stranding those items in an iCloud Drive directory the flipped album no
        // longer surfaces. Until the migration materializes evicted files
        // (`startDownloadingUbiquitousItem`) and verifies them locally before
        // uploading, .icloud -> .cloudKit is not offered through this engine.
        guard album.storageOption == .local else {
            throw MigrationError.invalidSourceStorage(album.storageOption)
        }

        state = .planning
        let enumerated = await enumerateItems(album: album)

        let store = MigrationPlanStore(album: album)
        let existing = await store.load()
        let merged = Self.merge(existing: existing?.items ?? [], enumerated: enumerated)

        let plan = MigrationPlan(
            albumName: album.name,
            sourceStorage: album.storageOption,
            items: merged,
            createdAt: existing?.createdAt ?? Date()
        )
        try await store.save(plan)

        publishProgress(plan)
        // Never publish a terminal state from planning: a finalize-retry resume
        // (every item already `sourceDeleted`) would otherwise report `.completed`
        // before `run()` retries finalize, tearing down the UI binding early and
        // dropping a second finalize failure. Terminal states belong to `run()`.
        state = .idle
        return plan
    }

    // MARK: - Launch-time resume

    /// Source albums that have an incomplete migration checkpoint on disk — surfaced
    /// on launch so the app can offer to resume (or auto-resume). Cheap: one file
    /// check per album, decrypting only those that actually have a checkpoint. A
    /// completed migration deletes its checkpoint (and flips the album to `.cloudKit`),
    /// so it never appears here.
    public func pendingPlans() async -> [Album] {
        var result: [Album] = []
        for album in albumManager.fetchAlbumsFromSources(includingHidden: true) {
            guard MigrationPlanStore.hasPlan(for: album) else { continue }
            // Skip a user-cancelled plan: it stays resumable on demand, but must never
            // be auto-restarted in the background against the user's explicit cancel.
            // Any OTHER surviving checkpoint is unfinished business — completion
            // deletes the file, so "no remaining per-item work" still means a pending
            // finalize (all items `sourceDeleted`, album not yet flipped), which must
            // be retried or the migrated album is unreachable on this device.
            if let plan = await MigrationPlanStore(album: album).load(),
               plan.cancelledAt == nil {
                result.append(album)
            }
        }
        return result
    }

    // MARK: - Execution

    /// Albums with a migration run in flight in THIS process. A second `start` for an
    /// album already running is a no-op, so a launch-time auto-resume racing a
    /// foreground resume, a BGTask firing during a live run, or a duplicate manager
    /// instance can never drive the same plan and the same files concurrently (which
    /// would clobber the checkpoint and double-upload / double-delete). Keyed by
    /// `album.id` so it spans separate manager instances; in-memory so a crash never
    /// leaves a stale lock across launches. Guarded by the `@MainActor` isolation.
    private static var activeAlbumIDs: Set<String> = []

    /// Whether a migration for the album is currently running in this process (any
    /// manager instance). Lets UI launchers detect the already-running case up
    /// front instead of registering a floating task that `start` silently orphans.
    public static func isActive(albumID: String) -> Bool {
        activeAlbumIDs.contains(albumID)
    }

    /// Claims the album for a run this engine does not drive — the CloudKit ->
    /// local move. Sharing the engine's active set means the overlay predicate
    /// (`isActive`) holds for both directions, and a forward `start` for the same
    /// album is refused while the reverse move is draining it (and vice versa).
    /// Returns `false` without claiming when the album is already active or an
    /// erase is in flight; the caller must not run.
    public static func claimExternalRun(albumID: String) -> Bool {
        guard !abortAllRequested, !activeAlbumIDs.contains(albumID) else { return false }
        activeAlbumIDs.insert(albumID)
        return true
    }

    /// Releases a claim taken with `claimExternalRun`. Must be called on every
    /// exit path of the external run, or the album stays unmigratable for the
    /// rest of the session.
    public static func releaseExternalRun(albumID: String) {
        activeAlbumIDs.remove(albumID)
    }

    /// Set by the erase flows: every in-flight run halts at its next item boundary
    /// WITHOUT saving a further checkpoint (the wipe removes them all), and new
    /// starts are refused — otherwise a live migration keeps rewriting its
    /// checkpoint and issuing CloudKit operations after the zone delete.
    private static var abortAllRequested = false

    public static func requestAbortAll() {
        abortAllRequested = true
    }

    /// Test-only: re-arm after an erase test so later tests can run migrations.
    static func _testClearAbortAll() {
        abortAllRequested = false
    }

    /// Plans (or resumes) then runs the migration to completion. Safe to call again
    /// after a crash/kill: it picks up from the persisted checkpoint and never
    /// re-uploads or re-deletes an item that already advanced.
    /// Returns `false` — without any state transition — when the album is already
    /// being migrated by another run in this process; callers driving UI must not
    /// register progress surfaces for a start that didn't claim the album.
    @discardableResult
    public func start(album: Album) async -> Bool {
        // Check-and-claim is atomic on the main actor (no await in between), so two
        // concurrent starts for the same album can't both pass the guard.
        guard !Self.abortAllRequested, !Self.activeAlbumIDs.contains(album.id) else { return false }
        Self.activeAlbumIDs.insert(album.id)
        defer { Self.activeAlbumIDs.remove(album.id) }
        // Claim `control` HERE, before planning — never inside `run()`. The UI
        // registers its cancellation handler as soon as the task is added, so a
        // cancel can land while planning or the preflights are still in flight;
        // resetting `control` any later would silently discard that request and
        // migrate against an explicit user cancel.
        control = .running
        do {
            let plan = try await plan(album: album)
            await run(album: album, initialPlan: plan)
        } catch let MigrationError.invalidSourceStorage(storage) {
            state = .failed(.other("Cannot migrate a \(storage.rawValue) album"))
        } catch {
            state = .failed(.other("\(error)"))
        }
        return true
    }

    /// Drives every not-yet-done item through upload -> verify -> delete-source,
    /// persisting the plan after each transition. The CloudKit upload goes through
    /// the SAME coordinator the live app uses, so the migrated album's index and
    /// blob cache are populated exactly as a fresh CloudKit save would leave them.
    private func run(album: Album, initialPlan: MigrationPlan) async {
        let target = Self.cloudKitAlbum(from: album)
        // Fail closed if the keyed hash cannot be derived: `album.id` embeds the
        // CLEARTEXT album name, so any fallback would persist it server-side —
        // and in a namespace the reconciler (which skips unhashable albums) could
        // never match, pull, or tombstone.
        guard let albumIDHash = deriveAlbumIDHash(for: album) else {
            printDebug("run ABORT — could not derive albumIDHash for album=\(album.name)")
            state = .failed(.other("Could not derive the album's iCloud identifier"))
            return
        }
        let store = makeStore(albumIDHash)
        activeStore = store
        defer { activeStore = nil }
        // Backstop so a phase can never outlive the run on a path that returns
        // without publishing (the account/zone/album-record aborts below). The
        // terminal paths that DO publish clear it explicitly first, so the last
        // snapshot the UI sees already carries `nil`.
        defer { currentPhase = nil }

        // Zone creation and the album record are real work with no per-item
        // progress to show; the overlay reports them as "Preparing". Both the state
        // and the phase are claimed HERE rather than after the preflights, because
        // this window IS the run: reporting `.idle` with no phase through zone
        // creation and the album-record save left the blocking overlay covering the
        // grid with nothing to name, and `setPhase` (not a bare assignment) is what
        // gets it onto the UI — a phase that is only recorded is invisible.
        state = .running
        setPhase(.preparing, plan: initialPlan)

        printDebug("run start album=\(album.name) storage=\(album.storageOption) items=\(initialPlan.items.count) albumIDHash=\(albumIDHash)")

        guard await store.accountAvailable() else {
            printDebug("run ABORT — iCloud account unavailable")
            state = .failed(.accountUnavailable)
            return
        }
        // A zone that failed to materialize used to be swallowed outright, and the run
        // then failed every item one by one with no hint that the zone was the cause.
        do {
            try await store.ensureZoneExists()
            printDebug("run zone ready")
        } catch {
            printDebug("run WARNING ensureZoneExists failed: \(error) — continuing, but uploads will likely fail")
        }

        // The album record MUST exist before any media is uploaded into it. Every
        // EncMedia record sets `parent` to the owning EncAlbum, and CloudKit
        // requires a `parent` target to already exist on the server (or be saved in
        // the same operation) — otherwise the save is rejected with
        // `CKError.referenceViolation` (31). Only the album reconciler used to
        // create this record, on its own schedule, so migrating an album the
        // reconciler had not yet pushed failed EVERY item with a reference
        // violation. `saveAlbum` is idempotent, so doing it here is safe even when
        // the reconciler already got there first.
        do {
            try await store.saveAlbum(CloudKitAlbumUpload(
                albumID: albumIDHash,
                encName: album.encryptedPathComponent,
                createdAt: album.creationDate,
                isHidden: albumManager.isAlbumHidden(album)
            ))
            printDebug("run album record ready albumID=\(albumIDHash)")
        } catch {
            // Without the parent record every upload below will fail the same way,
            // so fail fast with the real reason instead of N reference violations.
            printDebug("run ABORT saveAlbum FAILED albumID=\(albumIDHash) error=\(error)")
            if case .underlying(let underlying) = Self.unwrapPartial(mapCKError(error)),
               let ckError = underlying as? CKError, ckError.code == .invalidArguments {
                // "Cannot create new type EncAlbum in production schema" — the
                // Production environment never got the schema deploy. Distinct
                // reason so the alert is actionable instead of "Partial failure".
                state = .failed(.schemaNotDeployed)
            } else {
                state = .failed(.other("Could not create the album in iCloud: \(error)"))
            }
            return
        }

        // The SHARED blob cache, not a fresh instance: separate instances write
        // `.cacheindex.json` from divergent snapshots and clobber each other (see
        // `CloudKitBlobCache.shared`), and a private cache would leave the shared
        // one ignorant of the migrated blobs — its next persist would orphan them,
        // breaking the "blob is in the on-device cache" claim at the delete site.
        let coordinator = CloudKitSyncCoordinator(
            albumID: albumIDHash,
            store: store,
            cache: CloudKitBlobCache.shared,
            indexStore: MediaIndexStore(album: target)
        )
        let planStore = MigrationPlanStore(album: album)
        let sourceModel = albumManager.storageModel(for: album)

        var plan = initialPlan

        // Honor a pause/cancel that arrived during planning or the preflights
        // above. `control` is claimed in `start()` and never reset here, so a
        // request from that window survives to this check — and it must run even
        // for a zero-item plan, which skips the loop and would otherwise finalize
        // (flip the album to CloudKit) straight past an explicit cancel.
        if await honorPendingControl(&plan, planStore: planStore, store: store) { return }

        for index in plan.items.indices where !plan.items[index].state.isDone {
            // An erase is wiping everything: stop issuing CloudKit operations and
            // do NOT write another checkpoint (the erase removes them).
            if Self.abortAllRequested {
                store.cancelAll()
                state = .idle
                return
            }
            // Honor a pause/cancel requested between items.
            if await honorPendingControl(&plan, planStore: planStore, store: store) { return }

            publishProgress(plan, currentItemName: plan.items[index].mediaID)
            do {
                try await migrateItem(at: index,
                                      in: &plan,
                                      planStore: planStore,
                                      store: store,
                                      coordinator: coordinator,
                                      sourceModel: sourceModel,
                                      albumIDHash: albumIDHash)
                // The stale-verification recovery resets a `verified` item to
                // `pending` and returns — the only way an item comes back
                // `pending`. The single-pass loop would then end the run as a
                // silent `.idle`, which the launcher reports as a user cancel.
                // Re-drive the item in place; if it comes back `pending` AGAIN
                // (the record keeps vanishing), surface a real failure instead.
                if plan.items[index].state == .pending {
                    try await migrateItem(at: index,
                                          in: &plan,
                                          planStore: planStore,
                                          store: store,
                                          coordinator: coordinator,
                                          sourceModel: sourceModel,
                                          albumIDHash: albumIDHash)
                    if plan.items[index].state == .pending {
                        markFailed(&plan, index,
                                   MigrationError.verificationFailed(recordName: plan.items[index].recordName))
                        try? await planStore.save(plan)
                    }
                }
            } catch let rawError as CloudKitMediaStoreError {
                // Non-retryable, run-halting failures keep the item recoverable.
                // Unwrap `.partial` first: the real adapter reports a
                // CKModifyRecordsOperation's per-record failure wrapped in
                // `.partialFailure`, so quota/account would otherwise never match.
                let error = Self.unwrapPartial(rawError)
                switch error {
                case .quotaExceeded:
                    markFailed(&plan, index, error)
                    try? await planStore.save(plan)
                    state = .failed(.quota)
                    currentPhase = nil
                    publishProgress(plan)
                    return
                case .accountUnavailable:
                    markFailed(&plan, index, error)
                    try? await planStore.save(plan)
                    state = .failed(.accountUnavailable)
                    currentPhase = nil
                    publishProgress(plan)
                    return
                case .cancelled:
                    // Treat an aborted op like a cancel: revert and stop, resumable. If
                    // the user explicitly cancelled, mark it durable so background
                    // auto-resume won't silently restart it; a system-aborted op stays
                    // freely resumable.
                    Self.revertInFlight(&plan)
                    if control == .cancelRequested { plan.cancelledAt = Date() }
                    try? await planStore.save(plan)
                    state = .idle
                    currentPhase = nil
                    publishProgress(plan)
                    return
                default:
                    markFailed(&plan, index, error)
                    try? await planStore.save(plan)
                }
            } catch {
                markFailed(&plan, index, error)
                try? await planStore.save(plan)
            }
            publishProgress(plan, currentItemName: plan.items[index].mediaID)
        }

        if !plan.hasRemainingWork {
            // No remaining work — every item is done, or there were none to begin
            // with (an empty album must still flip to CloudKit rather than wedge
            // forever with an orphaned zero-item checkpoint that `pendingPlans()`
            // can never surface).
            // A zero-item plan for an album whose CloudKit discovery marker already
            // exists is not an empty album: it is a re-run against an album that
            // already finalized (source drained, checkpoint deleted). Don't
            // re-finalize — just drop the zero-item checkpoint this run's plan()
            // re-created. (Source-dir existence can't be the signal: enumeration
            // re-creates the directory via `initializeDirectories`.)
            if plan.items.isEmpty {
                let marker = CloudKitStorageModel.albumsURL.appendingPathComponent(target.encryptedPathComponent)
                if FileManager.default.fileExists(atPath: marker.path) {
                    await planStore.delete()
                    state = .idle
                    currentPhase = nil
                    publishProgress(plan)
                    return
                }
            }
            // Flip the album's identity to CloudKit (marker + drop drained source dir),
            // then clean up the now-stale source index and the checkpoint. The bytes
            // are already durable in CloudKit (verified) and cached locally.
            // Finalize failure (marker unwritable) must KEEP the checkpoint: the
            // marker is the album's only discovery mechanism, so destroying the plan
            // here would leave the album safe in CloudKit but reachable nowhere on
            // this device, with no retry state. A kept checkpoint retries finalize
            // on the next resume.
            do {
                _ = try albumManager.finalizeMigrationToCloudKit(album: album)
            } catch {
                printDebug("run FINALIZE FAILED album=\(album.name) error=\(error) — checkpoint kept for retry")
                state = .failed(.other("Could not finish the album move: \(error)"))
                currentPhase = nil
                publishProgress(plan)
                return
            }
            try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
            await planStore.delete()
            printDebug("run COMPLETED album=\(album.name) items=\(plan.items.count)")
            state = .completed
        } else if plan.failedCount > 0 {
            // Include the first item's error. Each failure already records its
            // mapped CKError in `lastError`, but nothing ever read it back, so the
            // count was the only thing that reached the user — and a bare
            // "N item(s) failed" says nothing about whether the cause was a
            // missing zone, a network drop, or a schema mismatch.
            let failedNames = plan.items.filter { $0.state == .failed }.map(\.recordName)
            printDebug("run FAILED album=\(album.name) failedCount=\(plan.failedCount) of \(plan.items.count) recordNames=\(failedNames)")
            let firstError = plan.items.first(where: { $0.state == .failed })?.lastError
            state = .failed(.other(firstError.map { "\(plan.failedCount) item(s) failed: \($0)" }
                                   ?? "\(plan.failedCount) item(s) failed"))
        } else {
            state = .idle
        }
        // The run is over in every branch above — completed, failed or idle — so the
        // final snapshot the UI sees must not still claim a phase.
        currentPhase = nil
        publishProgress(plan)
    }

    /// Honors a pending pause/cancel request at a safe boundary (between items, or
    /// before the run's first item). Returns `true` when the run must stop; the
    /// plan is checkpointed and the terminal snapshot published in either case.
    /// A cancel is stamped durable (`cancelledAt`) so background auto-resume skips
    /// the plan, while an on-demand resume can still finish it.
    private func honorPendingControl(_ plan: inout MigrationPlan,
                                     planStore: MigrationPlanStore,
                                     store: CloudKitMediaStoring) async -> Bool {
        switch control {
        case .pauseRequested:
            state = .paused
            try? await planStore.save(plan)
            currentPhase = nil
            publishProgress(plan)
            return true
        case .cancelRequested:
            store.cancelAll()
            Self.revertInFlight(&plan)
            plan.cancelledAt = Date()   // durable cancel: kept on disk, but auto-resume skips it
            try? await planStore.save(plan)
            state = .idle
            currentPhase = nil
            publishProgress(plan)
            return true
        case .running:
            return false
        }
    }

    private func markFailed(_ plan: inout MigrationPlan, _ index: Int, _ error: Error) {
        plan.items[index].state = .failed
        plan.items[index].lastError = "\(error)"
        printDebug("item FAILED recordName=\(plan.items[index].recordName) error=\(error)")
    }

    /// Resets any item left mid-upload back to `pending` so a resume re-drives it
    /// cleanly. `verified`/`sourceDeleted`/`uploaded` work is preserved.
    static func revertInFlight(_ plan: inout MigrationPlan) {
        for index in plan.items.indices where plan.items[index].state == .uploading {
            plan.items[index].state = .pending
        }
    }

    // MARK: - Pause / Resume / Cancel

    /// Requests a pause at the next item boundary. The current item finishes its
    /// in-flight transition first, so the checkpoint is never left torn.
    public func pause() {
        guard state == .running else { return }
        control = .pauseRequested
    }

    /// Resumes a paused/failed/partial migration from its on-disk checkpoint.
    public func resume(album: Album) async {
        await start(album: album)
    }

    /// Stops the migration and reverts any in-flight item to `pending`. The album stays
    /// fully usable in its source storage (nothing verified was deleted). Aborts an
    /// upload already in flight and records a durable cancel, so the migration is not
    /// silently auto-resumed in the background — but the checkpoint is kept so the user
    /// can still resume on demand (recovering any item that already moved to CloudKit).
    public func cancel(album: Album) async {
        control = .cancelRequested
        activeStore?.cancelAll()                  // abort an upload already in flight
        guard state != .running else { return }   // a running loop performs the revert itself
        let store = MigrationPlanStore(album: album)
        guard var plan = await store.load() else { state = .idle; currentPhase = nil; return }
        Self.revertInFlight(&plan)
        plan.cancelledAt = Date()
        try? await store.save(plan)
        state = .idle
        currentPhase = nil
        publishProgress(plan)
    }

    /// One item's resumable state machine. Each phase is guarded by the persisted
    /// state and advances it exactly one step, persisting before moving on — so a
    /// crash between any two phases resumes correctly. Re-uploading is avoided by
    /// re-verifying an interrupted `uploading` item rather than blindly re-saving
    /// (a stable record name + `ifServerRecordUnchanged` would otherwise conflict).
    private func migrateItem(at index: Int,
                             in plan: inout MigrationPlan,
                             planStore: MigrationPlanStore,
                             store: CloudKitMediaStoring,
                             coordinator: CloudKitSyncCoordinator,
                             sourceModel: DataStorageModel?,
                             albumIDHash: String) async throws {
        let item = plan.items[index]
        let encURL = sourceModel?.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
        let previewURL = sourceModel?.previewURLForMedia(withID: item.mediaID)

        // Recover an interrupted upload: confirm-or-restart rather than re-save.
        if plan.items[index].state == .uploading {
            if try await isPresentInCloudKit(item, store: store) {
                plan.items[index].state = .uploaded
            } else {
                plan.items[index].state = .pending
            }
            try await planStore.save(plan)
        }

        // 1. Upload the existing ciphertext (no re-encryption).
        if plan.items[index].state == .pending || plan.items[index].state == .failed {
            // No source ciphertext means a stale index entry with nothing to migrate.
            // Skip it terminally rather than failing it forever — a single missing file
            // must never wedge the whole album short of completion.
            guard let encURL, FileManager.default.fileExists(atPath: encURL.path) else {
                printDebug("item SKIPPED recordName=\(item.recordName) — source ciphertext missing at \(encURL?.lastPathComponent ?? "<no url>")")
                plan.items[index].state = .skipped
                plan.items[index].lastError = "source ciphertext missing"
                try await planStore.save(plan)
                return
            }

            plan.items[index].state = .uploading
            plan.items[index].lastError = nil
            try await planStore.save(plan)

            let thumbURL = previewURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let upload = CloudKitMediaUpload(
                albumID: albumIDHash,
                mediaID: item.mediaID,
                mediaType: item.mediaType,
                createdAt: item.createdAt,
                sizeBytes: item.sizeBytes,
                encryptedFileURL: encURL,
                encryptedThumbURL: thumbURL,
                recordName: item.recordName
            )
            setPhase(.uploading, plan: plan, currentItemName: item.mediaID)
            do {
                try await uploadWithRetry(upload, coordinator: coordinator, plan: plan, itemName: item.mediaID)
            } catch let error as CloudKitMediaStoreError {
                // A record with this stable name is already on the server (e.g. a prior
                // run whose checkpoint was lost re-uploaded it): the bytes are there, so
                // don't re-save into a conflict loop — fall through to the verify gate,
                // which confirms presence (and size) before any source delete. The real
                // adapter wraps the per-record `.conflict` in `.partial`, so unwrap.
                guard case .conflict = Self.unwrapPartial(error) else { throw error }
                printDebug("item upload conflict recordName=\(item.recordName) — record already on server, falling through to verify")
            }
            printDebug("item uploaded recordName=\(item.recordName)")
            plan.items[index].state = .uploaded
            try await planStore.save(plan)
        }

        // 2. Verify the record is durably in CloudKit before touching the original.
        if plan.items[index].state == .uploaded {
            setPhase(.verifying, plan: plan, currentItemName: item.mediaID)
            guard try await isPresentInCloudKit(item, store: store) else {
                printDebug("item VERIFY FAILED recordName=\(item.recordName) — refusing to delete the local original")
                throw MigrationError.verificationFailed(recordName: item.recordName)
            }
            plan.items[index].state = .verified
            try await planStore.save(plan)
        }

        // 3. Delete the local original (true move). The blob is in CloudKit AND in
        // the on-device CloudKit cache (`coordinator.upload` stored it), so this
        // never removes the last copy.
        if plan.items[index].state == .verified {
            // A cancel requested mid-item stops BEFORE this irreversible delete: the
            // verified bytes are safe in CloudKit and the local original is untouched,
            // so the album stays fully usable in its source storage.
            if control == .cancelRequested { throw CloudKitMediaStoreError.cancelled }
            // An item that ENTERED this call already `verified` carries a verification
            // from an earlier run — arbitrarily stale (the record may have been erased
            // from another device, or the zone deleted, since). Never delete a local
            // original against a stale verification: re-verify with the same cheap
            // fetch-by-id first, and re-drive the upload if the record is gone.
            if item.state == .verified {
                setPhase(.verifying, plan: plan, currentItemName: item.mediaID)
                guard try await isPresentInCloudKit(item, store: store) else {
                    printDebug("item STALE VERIFICATION recordName=\(item.recordName) — record gone since the earlier run, re-driving upload")
                    plan.items[index].state = .pending
                    plan.items[index].lastError = "stale verification: record no longer in CloudKit"
                    try await planStore.save(plan)
                    return
                }
            }
            printDebug("item deleting source recordName=\(item.recordName) verified in CloudKit")
            setPhase(.removingLocalCopy, plan: plan, currentItemName: item.mediaID)
            if let encURL { try? FileManager.default.removeItem(at: encURL) }
            // The preview is NOT deleted: it lives in the global, storage-agnostic
            // thumbnail directory that the migrated `.cloudKit` album reads from
            // the same path (mirroring `exportCiphertext` in the reverse
            // direction). Deleting it would force a thumbnail re-download for
            // every item — and for a Live Photo would strip the shared preview
            // before its second component uploads.
            plan.items[index].state = .sourceDeleted
            try await planStore.save(plan)
        }
    }

    /// Uploads with bounded `retry(after:)` backoff (honoring CloudKit's requested
    /// delay). Non-retryable errors (quota, account, conflict, …) propagate so the
    /// run loop can halt or fail the item as appropriate.
    /// `plan`/`itemName` are carried purely so the backoff can publish `.retrying` —
    /// a long CloudKit-requested delay is otherwise indistinguishable from a stall.
    private func uploadWithRetry(_ upload: CloudKitMediaUpload,
                                 coordinator: CloudKitSyncCoordinator,
                                 plan: MigrationPlan,
                                 itemName: String) async throws {
        var attempt = 0
        while true {
            do {
                _ = try await coordinator.upload(upload, progress: { _ in })
                return
            } catch let error as CloudKitMediaStoreError {
                guard case .retry(let after) = Self.unwrapPartial(error) else { throw error }
                attempt += 1
                if attempt > Self.maxRetriesPerItem { throw CloudKitMediaStoreError.retry(after: after) }
                setPhase(.retrying, plan: plan, currentItemName: itemName)
                let capped = min(max(after, 0), 30)
                if capped > 0 { try await Task.sleep(nanoseconds: UInt64(capped * 1_000_000_000)) }
                setPhase(.uploading, plan: plan, currentItemName: itemName)
            }
        }
    }

    /// Unwraps a `.partial` to its underlying per-record error. Migration saves are
    /// single-record operations, so a partial failure carries exactly one error —
    /// the operation's real failure. With several, unwrap only when every record
    /// agrees (e.g. quota fails them all identically); otherwise keep `.partial`.
    static func unwrapPartial(_ error: CloudKitMediaStoreError) -> CloudKitMediaStoreError {
        guard case .partial(let failed) = error, !failed.isEmpty else { return error }
        let mapped = failed.values.map { unwrapPartial(mapCKError($0)) }
        if mapped.count == 1 { return mapped[0] }
        // Multiple records: unwrap only the run-halting cases when every record
        // agrees (quota/account failures hit them all identically).
        if mapped.allSatisfy({ if case .quotaExceeded = $0 { return true } else { return false } }) {
            return .quotaExceeded
        }
        if mapped.allSatisfy({ if case .accountUnavailable = $0 { return true } else { return false } }) {
            return .accountUnavailable
        }
        return error
    }

    /// Whether the item's record exists in CloudKit with the expected size — the
    /// verification gate that must pass before a source delete. Uses a strongly-consistent
    /// fetch-by-record-ID (not the eventually-consistent `fetchMetadata` query), so a
    /// record saved moments earlier is reliably seen rather than spuriously reported
    /// missing — which would otherwise fail the item and strand the migration.
    private func isPresentInCloudKit(_ item: MigrationItem,
                                     store: CloudKitMediaStoring) async throws -> Bool {
        guard let metadata = try await store.fetchRecordMetadata(recordName: item.recordName) else {
            printDebug("verify MISS recordName=\(item.recordName) — record absent from CloudKit after a successful upload")
            return false
        }
        // A size mismatch and an absent record both used to return a bare `false`,
        // so a verification failure said nothing about which had happened.
        guard metadata.sizeBytes == item.sizeBytes else {
            printDebug("verify SIZE MISMATCH recordName=\(item.recordName) local=\(item.sizeBytes) remote=\(metadata.sizeBytes)")
            return false
        }
        printDebug("verify ok recordName=\(item.recordName) sizeBytes=\(item.sizeBytes)")
        return true
    }

    /// The `.cloudKit` twin of a source album (same name + key) the upload stack
    /// targets, so the migrated index/blobs land under the album's CloudKit identity.
    static func cloudKitAlbum(from album: Album) -> Album {
        Album.cloudKitTwin(of: album)
    }

    /// A side-effect-free pre-flight estimate (item count + total bytes) for the
    /// warning alert. Unlike `plan(album:)` it does NOT persist a checkpoint, so
    /// merely previewing — then cancelling — never leaves a plan that would
    /// auto-resume on the next launch.
    public func estimate(album: Album) async -> (itemCount: Int, totalBytes: Int64) {
        guard album.storageOption == .local else { return (0, 0) }
        let items = await enumerateItems(album: album)
        return (items.count, items.reduce(0) { $0 + $1.sizeBytes })
    }

    // MARK: - Enumeration

    /// Reads every encrypted component of the source album into a fresh `pending`
    /// work item, sized from the on-disk ciphertext and dated from its index
    /// metadata. Live Photos contribute one item per component (each is a record).
    private func enumerateItems(album: Album) async -> [MigrationItem] {
        let directoryModel = albumManager.storageModel(for: album)

        let backend = DiskMediaBackend()
        await backend.configure(for: album, albumManager: albumManager)
        let mediaWithMetadata = await backend.enumerateMediaWithMetadata()

        var items: [MigrationItem] = []
        for entry in mediaWithMetadata {
            let createdAt = entry.dateTaken ?? entry.dateEncrypted ?? album.creationDate
            for component in entry.media.underlyingMedia {
                let url = directoryModel?.driveURLForMedia(withID: component.id, type: component.mediaType)
                let size = url.flatMap(Self.fileSize(at:)) ?? 0
                items.append(MigrationItem(
                    mediaID: component.id,
                    recordName: CloudKitFileAccess.componentRecordName(mediaID: component.id, type: component.mediaType),
                    mediaType: component.mediaType,
                    createdAt: createdAt,
                    sizeBytes: size
                ))
            }
        }
        return items
    }

    // MARK: - Merge

    /// Folds a freshly-enumerated item list into any existing plan: items that
    /// already made progress (uploading/uploaded/verified) keep their state and
    /// operation id; `pending`/`failed` items are refreshed to a clean `pending`
    /// with the current size so they retry; terminal `sourceDeleted` items whose
    /// source file is already gone are preserved even though enumeration can't see
    /// them. Order follows enumeration, with preserved-but-absent items appended.
    static func merge(existing: [MigrationItem], enumerated: [MigrationItem]) -> [MigrationItem] {
        let priorByRecord = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [MigrationItem] = []
        var seen = Set<String>()

        for fresh in enumerated {
            seen.insert(fresh.recordName)
            if let prior = priorByRecord[fresh.recordName], prior.state != .pending, prior.state != .failed {
                result.append(prior)            // preserve in-progress / verified / done
            } else {
                result.append(fresh)            // (re)start as pending with current size
            }
        }

        // An item that already made progress (its bytes are in CloudKit) or is terminal
        // may be absent from enumeration — a `sourceDeleted`/`skipped` item has no source
        // file, and an in-progress item's file can vanish out of band. Preserve all of
        // them so confirmed work is never silently dropped (which would let the album
        // finalize having skipped or lost an item that already moved). Only absent fresh
        // `pending`/`failed` phantoms — no confirmed CloudKit copy — are discarded.
        for item in existing where !seen.contains(item.recordName)
            && item.state != .pending && item.state != .failed {
            result.append(item)
        }
        return result
    }

    // MARK: - Helpers

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
