//
//  CloudKitMigrationManager.swift
//  EncameraCore
//
//  The one engine that moves ciphertext between local storage and CloudKit: a whole
//  album or selected items, in either direction. The existing sync stack does the
//  transport (`CloudKitSyncCoordinator`); this manager sequences the work through a
//  per-direction `MigrationItemStep` and checkpoints every step to disk so a
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

/// Who started a run. A run the user started clears the plan's `lastFailure`; an
/// automatic resume (launch, background task) keeps it, so a plan that failed is
/// still known as failed while it is retried in the background.
public enum MigrationRunTrigger: Sendable {
    case user
    case automaticResume
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
    /// Downloading evicted iCloud Drive files back onto the device so they can be
    /// uploaded. Only ever reached by an `.icloud` source; a local album's files are
    /// already where the uploader needs them.
    case materializing
    case uploading
    case verifying
    case removingLocalCopy
    case retrying
    // The CloudKit -> local direction.
    case downloading
    case removingRemoteCopy
}

/// Where a run is when it calls `CloudKitMigrationManager.boundaryHook`.
public enum MigrationBoundary: Equatable, Sendable {
    /// An item finished its step in the main loop; `verified` counts the plan's
    /// verified and source-deleted items.
    case transferred(verified: Int)
    /// The second pass of a whole album moving back to this device, before its next
    /// record removal. `removed: 0` is the boundary between the two passes.
    case removing(removed: Int)
    /// An item has verified at its destination and its source copy is about to be
    /// removed, in any run that removes each source copy as its item verifies.
    /// `removed` counts the plan's items whose source copy is already gone.
    case removingSource(removed: Int)
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
    /// Items whose source copy has been removed.
    public var removedCount: Int
    /// Items whose source copy this run removes: every item but a skipped one. The
    /// denominator of "Removing X of Y".
    public var removalTotal: Int

    public init(fractionComplete: Double = 0,
                verifiedCount: Int = 0,
                totalCount: Int = 0,
                failedCount: Int = 0,
                totalBytes: Int64 = 0,
                currentItemName: String? = nil,
                phase: MigrationPhase? = nil,
                removedCount: Int = 0,
                removalTotal: Int = 0) {
        self.fractionComplete = fractionComplete
        self.verifiedCount = verifiedCount
        self.totalCount = totalCount
        self.failedCount = failedCount
        self.totalBytes = totalBytes
        self.currentItemName = currentItemName
        self.phase = phase
        self.removedCount = removedCount
        self.removalTotal = removalTotal
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
                  phase: phase,
                  removedCount: plan.sourceDeletedCount,
                  removalTotal: plan.items.count - plan.skippedCount)
    }

    /// The 1-based position of the item being removed, for "Removing X of Y". Holds
    /// at `removalTotal` once the last one is gone.
    public var removingItemNumber: Int { min(removedCount + 1, removalTotal) }
}

extension MigrationProgress: CustomStringConvertible {
    public var description: String {
        let percent = String(format: "%.1f", fractionComplete * 100)
        return "fraction=\(percent)% verified=\(verifiedCount)/\(totalCount) removed=\(removedCount)/\(removalTotal) failed=\(failedCount) bytes=\(totalBytes) phase=\(phase?.rawValue ?? "nil") item=\(currentItemName ?? "nil")"
    }
}

public enum MigrationError: Error, Equatable {
    /// Only `.local` and `.icloud` albums can be planned by `plan(album:)`. A
    /// `.cloudKit` album moves back with an album-scope plan through `start(plan:)`.
    case invalidSourceStorage(StorageType)
    /// The record did not appear in CloudKit after upload (verification failed); the
    /// source is never deleted in this case.
    case verificationFailed(recordName: String)
    /// The server's albums could not be listed while choosing the CloudKit album a
    /// move to CloudKit lands in. Retryable; the plan is not written.
    case cloudKitAlbumLookupFailed(String)
}

// MARK: - Manager

/// The ids in `CloudKitMigrationManager`'s active set, readable from any thread.
private final class ActiveAlbumIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func remove(_ id: String) { lock.withLock { _ = ids.remove(id) } }
}

@MainActor
public final class CloudKitMigrationManager: ObservableObject, DebugPrintable {

    @Published public private(set) var state: MigrationState = .idle {
        didSet {
            guard state != oldValue else { return }
            printDebug("state \(oldValue) -> \(state)")
        }
    }
    @Published public private(set) var progress: MigrationProgress = .idle

    /// Cooperative control checked between items so `pause`/`cancel` (also on the
    /// main actor) take effect at the next safe boundary without interrupting an
    /// item mid-transition.
    private enum RunControl { case running, pauseRequested, cancelRequested }
    private var control: RunControl = .running
    /// Set while a whole album's CloudKit records are being removed, when a cancel
    /// is no longer honored.
    private var isRemovingSources = false
    /// Set when the run stopped because a key it needed is not on this device, so
    /// the persisted failure can say so. Reset at every claim.
    private var failedForMissingKey = false

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
    ///
    /// A run in flight whose plan has no items yet is the placeholder a whole album
    /// moving back to this device starts from, before the CloudKit index is read. An
    /// empty plan reads as complete, so it is published as 0% instead of a full ring.
    private func publishProgress(_ plan: MigrationPlan, currentItemName: String? = nil) {
        var snapshot = MigrationProgress(plan: plan, currentItemName: currentItemName, phase: currentPhase)
        if plan.items.isEmpty, currentPhase != nil { snapshot.fractionComplete = 0 }
        progress = snapshot
        logProgressIfChanged(snapshot)
    }

    /// The last snapshot `logProgressIfChanged` wrote, so the log carries one line
    /// per meaningful change rather than one per publish.
    private var lastLoggedProgress: MigrationProgress?

    /// Logs a progress snapshot when anything but the materializer's percentage
    /// ticks (published as the item name) changed since the last line.
    private func logProgressIfChanged(_ snapshot: MigrationProgress) {
        if snapshot.phase == .materializing, lastLoggedProgress?.phase == .materializing { return }
        guard snapshot != lastLoggedProgress else { return }
        lastLoggedProgress = snapshot
        printDebug("progress \(snapshot)")
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

    private let albumManager: AlbumManaging
    /// Test seam: supplies the `CloudKitMediaStoring` for an album's token namespace.
    /// Production reads `CloudKitStoreProvider.makeStore` at call time (so a UI-test
    /// mock installed there still wins); tests inject a fixed mock here.
    private let storeFactoryOverride: (@Sendable (String) -> CloudKitMediaStoring)?
    /// Brings evicted iCloud Drive files back onto disk. Injected so the engine can
    /// be tested off-device: a simulator has no ubiquity container, so the real one
    /// can never download anything there.
    private let materializer: ICloudDriveMaterializing
    /// Test seam: the chunk store the run's coordinator reads chunked blobs through.
    /// `nil` keeps the coordinator's default, the live CloudKit chunk store.
    private let chunkStoreOverride: ChunkedBlobStoring?

    public init(albumManager: AlbumManaging,
                storeFactory: (@Sendable (String) -> CloudKitMediaStoring)? = nil,
                materializer: ICloudDriveMaterializing? = nil,
                chunkStore: ChunkedBlobStoring? = nil) {
        self.albumManager = albumManager
        self.storeFactoryOverride = storeFactory
        self.materializer = materializer ?? ICloudDriveMaterializer()
        self.chunkStoreOverride = chunkStore
    }

    private func makeStore(_ namespace: String) -> CloudKitMediaStoring {
        storeFactoryOverride?(namespace) ?? CloudKitStoreProvider.makeStore(namespace)
    }

    // MARK: - Destination album

    /// The id of the CloudKit album `album` moves into. An album already on this
    /// device as a CloudKit album with the same name and key is that album; failing
    /// that, a server album whose `encName` decrypts under the key to the same name
    /// is adopted, so two devices moving the same album do not upload the same media
    /// records into two albums. Only when neither exists is a new id minted.
    ///
    /// A server album this device has queued for deletion is never adopted: its
    /// delete would cascade to the media uploaded into it.
    ///
    /// Throws when the server's albums cannot be listed: minting without looking
    /// would split the album whenever another device already moved it.
    private func resolveCloudKitAlbumID(for album: Album) async throws -> String {
        if let local = CloudKitAlbumMarker.albumID(matching: album) {
            printDebug("resolve albumID=\(local) — adopting this device's CloudKit album")
            return local
        }
        let records: [CloudKitAlbumMetadata]
        do {
            records = try await makeStore("").fetchAllAlbums()
        } catch let error as CloudKitMediaStoreError {
            let unwrapped = Self.unwrapPartial(error)
            if case .accountUnavailable = unwrapped { throw unwrapped }
            throw MigrationError.cloudKitAlbumLookupFailed("\(error)")
        } catch {
            throw MigrationError.cloudKitAlbumLookupFailed("\(error)")
        }
        let pendingDeletes = CloudKitAlbumDeleteQueue().pending()
        let match = records
            .filter { !pendingDeletes.contains($0.albumID) }
            .sorted { ($0.createdAt, $0.albumID) < ($1.createdAt, $1.albumID) }
            .first { Album.decryptedAlbumName($0.encName, key: album.key) == album.name }
        if let match {
            printDebug("resolve albumID=\(match.albumID) — adopting the server's album")
            return match.albumID
        }
        let minted = UUID().uuidString
        printDebug("resolve albumID=\(minted) — minted, no album with this name and key")
        return minted
    }

    // MARK: - Planning

    /// Builds (or resumes) the migration plan for `album`: enumerate every encrypted
    /// component, assign a stable `mediaID` + deterministic CloudKit record name, and
    /// persist the plan encrypted to disk. Re-planning a partially-migrated album
    /// yields identical ids and preserves the state of items that already made
    /// progress, so nothing is re-uploaded or lost. Never touches a `.cloudKit` album.
    ///
    /// The destination album's id is resolved the first time (see
    /// `resolveCloudKitAlbumID`) and persisted in the plan; a re-plan reuses it, so a
    /// resumed move can never land in a second album.
    @discardableResult
    public func plan(album: Album) async throws -> MigrationPlan {
        guard album.storageOption == .local || album.storageOption == .icloud else {
            throw MigrationError.invalidSourceStorage(album.storageOption)
        }

        state = .planning
        let store = MigrationPlanStore(album: album)
        let existing = await store.load()
        let cloudKitAlbumID: String
        if let persisted = existing?.destination.cloudKitAlbumID {
            cloudKitAlbumID = persisted
        } else {
            cloudKitAlbumID = try await resolveCloudKitAlbumID(for: album)
        }

        let enumerated = await enumerateItems(album: album)
        let merged = Self.merge(existing: existing?.items ?? [], enumerated: enumerated)

        var plan = try MigrationPlan.album(album, items: merged, createdAt: existing?.createdAt ?? Date(),
                                           cloudKitAlbumID: cloudKitAlbumID)
        plan.lastFailure = existing?.lastFailure
        try await store.save(plan)

        publishProgress(plan)
        state = .idle
        return plan
    }

    // MARK: - Launch-time resume

    /// Every plan on disk with unfinished business, in both scopes and both
    /// directions — surfaced on launch so the app can resume them. A completed run
    /// deletes its checkpoint, so it never appears here. A user-cancelled plan is
    /// skipped: it stays resumable on demand, but must never be auto-restarted in the
    /// background against the user's explicit cancel. Any OTHER surviving checkpoint
    /// is unfinished business — "no remaining per-item work" still means a pending
    /// finalize, which must be retried or the moved album is unreachable here.
    public func pendingPlans() async -> [MigrationPlan] {
        var result: [MigrationPlan] = []
        for album in albumManager.fetchAlbumsFromSources(includingHidden: true) {
            result += await MigrationPlanStore.plans(for: album).filter { $0.cancelledAt == nil }
        }
        return result
    }

    /// `pendingPlans()` without the plans whose last run failed in a way an automatic
    /// retry cannot fix yet (see `MigrationLastFailure.blocksAutomaticResume`): a full
    /// iCloud inside its retry window, a missing account, or a missing key with no key
    /// added since. Those stay on disk, resumable by the user.
    public func autoResumablePlans(now: Date = Date()) async -> [MigrationPlan] {
        var result: [MigrationPlan] = []
        var heldKeyNames: [KeyName]?
        var isAccountAvailable: Bool?
        for plan in await pendingPlans() {
            guard let failure = plan.lastFailure else {
                result.append(plan)
                continue
            }
            if failure.category == .missingKey, heldKeyNames == nil {
                heldKeyNames = ((try? albumManager.keyManager.storedKeys()) ?? []).map(\.name)
            }
            if failure.category == .accountUnavailable, isAccountAvailable == nil {
                let namespace = plan.destination.cloudKitAlbumID ?? plan.source.cloudKitAlbumID ?? plan.source.albumID
                isAccountAvailable = await makeStore(namespace).accountAvailable()
            }
            if failure.blocksAutomaticResume(now: now,
                                             isAccountAvailable: isAccountAvailable ?? true,
                                             heldKeyNames: heldKeyNames ?? []) {
                printDebug("autoResume SKIP plan=\(plan.id) source=\(plan.source.albumID) lastFailure=\(failure.category) at=\(failure.date)")
                continue
            }
            result.append(plan)
        }
        return result
    }

    /// The albums a plan's endpoints name on this device. An album-scope plan's
    /// destination is the source's twin on the other plane, which need not exist yet;
    /// an item-scope plan needs both albums. `nil` when an album is gone, and for a
    /// move to CloudKit whose destination album has not been resolved yet.
    public func albums(for plan: MigrationPlan) -> (source: Album, destination: Album)? {
        let albums = albumManager.fetchAlbumsFromSources(includingHidden: true)
        guard let source = albums.first(where: { $0.id == plan.source.albumID }) else { return nil }
        switch plan.scope {
        case .album:
            guard plan.destination.storage == .cloudKit else {
                return (source, Album.localTwin(of: source))
            }
            guard let albumID = plan.destination.cloudKitAlbumID else { return nil }
            return (source, Album.cloudKitTwin(of: source, albumID: albumID))
        case .items:
            guard let destination = albums.first(where: { $0.id == plan.destination.albumID }) else { return nil }
            return (source, destination)
        }
    }

    /// The plan's source album on this device, or nil when it is gone.
    private func sourceAlbum(for plan: MigrationPlan) -> Album? {
        albumManager.fetchAlbumsFromSources(includingHidden: true).first { $0.id == plan.source.albumID }
    }

    /// The album the last run moved into, once it is known: for a move to CloudKit
    /// that is only after planning has resolved the destination album's id.
    public private(set) var destinationAlbum: Album?

    // MARK: - Execution

    /// Albums with a migration run in flight in THIS process. A second `start` for an
    /// album already running is a no-op, so a launch-time auto-resume racing a
    /// foreground resume, a BGTask firing during a live run, or a duplicate manager
    /// instance can never drive the same plan and the same files concurrently (which
    /// would clobber the checkpoint and double-upload / double-delete). Keyed by
    /// `album.id` so it spans separate manager instances; in-memory so a crash never
    /// leaves a stale lock across launches. Claims and releases happen on the main
    /// actor, so check-and-claim stays atomic; the lock only lets `isActive` be read
    /// from any thread.
    private static let activeAlbumIDs = ActiveAlbumIDs()

    /// Whether a migration for the album is currently running in this process (any
    /// manager instance). Lets UI launchers detect the already-running case up
    /// front instead of registering a floating task that `start` silently orphans,
    /// and lets a rename refuse an album whose plan a run is rewriting.
    public nonisolated static func isActive(albumID: String) -> Bool {
        activeAlbumIDs.contains(albumID)
    }

    /// Slows each CloudKit -> local download so a UI test can observe the run,
    /// mirroring the mock store's upload delay. Zero outside UI tests.
    public static var downloadDelay: Duration {
        get { CloudKitToLocalStep.downloadDelay }
        set { CloudKitToLocalStep.downloadDelay = newValue }
    }

    /// UI-test seam, nil in production. Awaited at each item boundary so a device
    /// test can hold a run at an exact checkpoint and kill the app there, which no
    /// amount of timing can do against real CloudKit.
    public static var boundaryHook: ((MigrationBoundary) async -> Void)?

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

    /// Plans (or resumes) then runs the album's migration to CloudKit to completion.
    /// Safe to call again after a crash/kill: it picks up from the persisted
    /// checkpoint and never re-uploads or re-deletes an item that already advanced.
    /// Returns `false` — without any state transition — when the album is already
    /// being migrated by another run in this process; callers driving UI must not
    /// register progress surfaces for a start that didn't claim the album.
    ///
    /// The CloudKit album it lands in is resolved while planning, so only the source
    /// is claimed up front; the destination is claimed once the plan names it.
    ///
    /// A `.user` start clears the plan's `lastFailure`; an `.automaticResume` keeps it.
    @discardableResult
    public func start(album: Album, trigger: MigrationRunTrigger = .user) async -> Bool {
        await claimAndRun(source: album, destination: nil,
                          planID: MigrationPlan.albumPlanID, trigger: trigger) {
            try await self.plan(album: album)
        }
    }

    /// Runs `plan` to completion, in either scope and either direction. An
    /// album-scope move to CloudKit re-plans first, so files added since the plan
    /// was written are included. Returns `false` when either album is already being
    /// moved by another run in this process, or when an album the plan names is gone.
    @discardableResult
    public func start(plan: MigrationPlan, trigger: MigrationRunTrigger = .user) async -> Bool {
        if plan.scope == .album, plan.direction == .toCloudKit, let source = sourceAlbum(for: plan) {
            return await start(album: source, trigger: trigger)
        }
        var plan = plan
        if trigger == .user { plan.lastFailure = nil }
        guard let albums = albums(for: plan) else {
            printDebug("start ABORT plan=\(plan.id) — source or destination album not found")
            state = .failed(.other("The album this move belongs to is no longer on this device."))
            return false
        }
        return await claimAndRun(source: albums.source, destination: albums.destination,
                                 planID: plan.id, trigger: trigger) { plan }
    }

    /// Claims both albums, then plans and runs. The check-and-claim is atomic on the
    /// main actor (no await in between), so two concurrent starts touching either
    /// album can't both pass the guard; every claim is released on every exit.
    ///
    /// A nil `destination` is a move to CloudKit whose album the plan resolves: it is
    /// claimed after planning, and a destination already claimed by another run ends
    /// this one as `.idle` with `false`.
    ///
    /// When the run ends `.failed`, the failure is written to the plan's checkpoint
    /// (`MigrationLastFailure`); a `.user` start clears it before anything runs.
    private func claimAndRun(source: Album,
                             destination: Album?,
                             planID: String,
                             trigger: MigrationRunTrigger,
                             makePlan: () async throws -> MigrationPlan) async -> Bool {
        guard !Self.abortAllRequested,
              !Self.activeAlbumIDs.contains(source.id),
              !(destination.map { Self.activeAlbumIDs.contains($0.id) } ?? false) else { return false }
        var claimed = [source.id]
        if let destination { claimed.append(destination.id) }
        claimed.forEach { Self.activeAlbumIDs.insert($0) }
        defer { claimed.forEach { Self.activeAlbumIDs.remove($0) } }
        control = .running
        destinationAlbum = destination
        // A manager can drive several runs; none may start from the last one's
        // snapshot, or the ring opens already part- or fully-drawn.
        currentPhase = nil
        lastLoggedProgress = nil
        progress = .idle
        printDebug("claim source=\(source.id) destination=\(destination?.id ?? "<resolved by plan>")")
        defer { printDebug("run ended state=\(state) \(progress)") }
        failedForMissingKey = false
        let planStore = MigrationPlanStore(sourceAlbum: source, planID: planID)
        if trigger == .user {
            await planStore.clearLastFailure()
        }
        func runClaimed() async -> Bool {
            do {
                let plan = try await makePlan()
                let resolved: Album
                if let destination {
                    resolved = destination
                } else {
                    guard let albumID = plan.destination.cloudKitAlbumID else {
                        state = .failed(.other("The move has no destination album"))
                        return true
                    }
                    resolved = Album.cloudKitTwin(of: source, albumID: albumID)
                    guard !Self.activeAlbumIDs.contains(resolved.id) else {
                        printDebug("start ABORT — destination album=\(resolved.id) is already being moved into")
                        state = .idle
                        return false
                    }
                    Self.activeAlbumIDs.insert(resolved.id)
                    claimed.append(resolved.id)
                    destinationAlbum = resolved
                }
                await run(plan, source: source, destination: resolved)
            } catch let MigrationError.invalidSourceStorage(storage) {
                state = .failed(.other("Cannot migrate a \(storage.rawValue) album"))
            } catch MigrationError.cloudKitAlbumLookupFailed(let reason) {
                printDebug("start ABORT — could not look up the destination album: \(reason)")
                state = .failed(.other("Could not look up the album in iCloud. Check your connection and try again."))
            } catch CloudKitMediaStoreError.accountUnavailable {
                state = .failed(.accountUnavailable)
            } catch {
                state = .failed(.other("\(error)"))
            }
            return true
        }

        let claimedRun = await runClaimed()
        if case .failed(let reason) = state {
            await planStore.recordLastFailure(lastFailure(for: reason))
        }
        return claimedRun
    }

    /// The failure to persist for a run that ended `.failed(reason)`.
    private func lastFailure(for reason: MigrationFailureReason) -> MigrationLastFailure {
        let now = Date()
        switch reason {
        case .quota:
            return MigrationLastFailure(category: .quota, date: now)
        case .accountUnavailable:
            return MigrationLastFailure(category: .accountUnavailable, date: now)
        case .schemaNotDeployed, .other:
            guard failedForMissingKey else { return MigrationLastFailure(category: .other, date: now) }
            let held = ((try? albumManager.keyManager.storedKeys()) ?? []).map(\.name)
            return MigrationLastFailure(category: .missingKey, date: now, heldKeyNames: held)
        }
    }

    /// Drives every not-yet-done item through transfer -> verify -> remove-source,
    /// persisting the plan after each transition. Uploads go through the SAME
    /// coordinator the live app uses, so a migrated album's index and blob cache are
    /// populated exactly as a fresh CloudKit save would leave them.
    private func run(_ initialPlan: MigrationPlan, source: Album, destination: Album) async {
        let cloudAlbum = initialPlan.direction == .toCloudKit ? destination : source
        guard let albumID = cloudKitAlbumID(of: cloudAlbum),
              destinationNameIsFree(for: initialPlan, source: source, destination: destination) else { return }
        let store = makeStore(albumID)
        activeStore = store
        defer { activeStore = nil }
        defer { currentPhase = nil }

        state = .running
        setPhase(.preparing, plan: initialPlan)

        printDebug("run start plan=\(initialPlan.id) scope=\(initialPlan.scope) source=\(source.name)/\(source.storageOption) destination=\(destination.name)/\(destination.storageOption) items=\(initialPlan.items.count) albumID=\(albumID)")

        guard await prepareStore(store) else { return }
        let planStore = MigrationPlanStore(sourceAlbum: source, planID: initialPlan.id)
        let context = makeRunContext(for: initialPlan, source: source, destination: destination,
                                     albumID: albumID, store: store, planStore: planStore)
        guard await prepareDestination(for: initialPlan, context: context) else { return }

        var plan = initialPlan
        if plan.scope == .album, plan.direction == .toLocal {
            guard await replanFromCloudKitIndex(&plan, source: source, planStore: planStore) else { return }
        }
        if plan.scope == .items, plan.direction == .toCloudKit {
            await removeLeftoverSourceEntries(of: plan, source: source)
        }
        if await honorPendingControl(&plan, planStore: planStore, store: store,
                                    sourceModel: context.sourceModel) { return }

        let step: MigrationItemStep = plan.direction == .toCloudKit ? LocalToCloudKitStep() : CloudKitToLocalStep()
        guard let verifiedThisRun = await transferItems(&plan, step: step, context: context, planStore: planStore),
              await removeSourcesOnceAllVerified(&plan, step: step, context: context,
                                                 verifiedThisRun: verifiedThisRun, planStore: planStore) else { return }
        await finishRun(&plan, context: context, planStore: planStore)
    }

    // MARK: - Run setup

    /// The CloudKit side's album id, or nil — with the run failed — when it has none.
    private func cloudKitAlbumID(of cloudAlbum: Album) -> String? {
        guard let albumID = cloudAlbum.albumID else {
            printDebug("run ABORT — the CloudKit side has no albumID album=\(cloudAlbum.name)")
            state = .failed(.other("The album has no iCloud identifier"))
            return nil
        }
        return albumID
    }

    /// A whole album moving back becomes the local directory its name ciphertext
    /// names, so its name must be free on this device first. A directory already at
    /// that path is this move's own, from an earlier run. Fails the run on a clash.
    private func destinationNameIsFree(for plan: MigrationPlan, source: Album, destination: Album) -> Bool {
        guard plan.direction == .toLocal, plan.scope == .album,
              !FileManager.default.fileExists(atPath: LocalStorageModel(album: destination).baseURL.path),
              let clash = albumManager.albumNamed(source.name, otherThan: source) else { return true }
        printDebug("run ABORT — an album with the source's name already exists storage=\(clash.storageOption)")
        state = .failed(.other(L10n.albumExistsError))
        return false
    }

    /// Checks the iCloud account and makes sure the zone exists. Only a missing
    /// account stops the run; a zone failure surfaces through the transfers.
    private func prepareStore(_ store: CloudKitMediaStoring) async -> Bool {
        guard await store.accountAvailable() else {
            printDebug("run ABORT — iCloud account unavailable")
            state = .failed(.accountUnavailable)
            return false
        }
        do {
            try await store.ensureZoneExists()
            printDebug("run zone ready")
        } catch {
            printDebug("run WARNING ensureZoneExists failed: \(error) — continuing, but transfers will likely fail")
        }
        return true
    }

    private func makeRunContext(for plan: MigrationPlan,
                                source: Album,
                                destination: Album,
                                albumID: String,
                                store: CloudKitMediaStoring,
                                planStore: MigrationPlanStore) -> MigrationRunContext {
        let cloudAlbum = plan.direction == .toCloudKit ? destination : source
        // The SHARED blob cache, not a fresh instance: separate instances write
        // `.cacheindex.json` from divergent snapshots and clobber each other (see
        // `CloudKitBlobCache.shared`), and a private cache would leave the shared
        // one ignorant of the migrated blobs — its next persist would orphan them,
        // breaking the "blob is in the on-device cache" claim at the delete site.
        let coordinator = CloudKitSyncCoordinator(
            albumID: albumID,
            store: store,
            cache: CloudKitBlobCache.shared,
            indexStore: MediaIndexStore(album: cloudAlbum),
            sizeSidecar: AlbumSizeSidecar(album: cloudAlbum),
            chunkStore: chunkStoreOverride
        )
        return MigrationRunContext(
            source: source,
            destination: destination,
            sourceModel: albumManager.storageModel(for: source),
            destinationModel: plan.direction == .toLocal ? LocalStorageModel(album: destination) : nil,
            cloudKitAlbumID: albumID,
            coordinator: coordinator,
            store: store,
            savePlan: { plan in try await planStore.save(plan) },
            // The key library, read once for the whole run rather than per item: the
            // keychain query behind it is a full `SecItemCopyMatching`.
            storedKeys: (try? albumManager.keyManager.storedKeys()) ?? [],
            keyManager: albumManager.keyManager,
            isCancelRequested: { [weak self] in self?.control == .cancelRequested },
            noteMissingKey: { [weak self] in self?.failedForMissingKey = true },
            setPhase: { [weak self] phase, plan, itemName in
                self?.setPhase(phase, plan: plan, currentItemName: itemName)
            }
        )
    }

    /// Readies the destination before any item moves: the album record for a move
    /// to CloudKit, the local directory for a move back. Fails the run otherwise.
    private func prepareDestination(for plan: MigrationPlan, context: MigrationRunContext) async -> Bool {
        switch plan.direction {
        case .toCloudKit:
            return await saveAlbumRecord(for: context.destination, source: context.source,
                                         albumID: context.cloudKitAlbumID, store: context.store,
                                         scope: plan.scope)
        case .toLocal:
            // Bring the index current first so the move sees records uploaded from
            // another device moments ago rather than silently leaving them behind.
            do {
                try await context.coordinator.sync(albumID: context.cloudKitAlbumID)
            } catch {
                printDebug("run ABORT — reconcile of the source album failed: \(error)")
                state = .failed(.other("Could not bring the album up to date with iCloud: \(error)"))
                return false
            }
            do {
                try LocalStorageModel(album: context.destination).initializeDirectories()
            } catch {
                printDebug("run ABORT — could not initialize the local destination: \(error)")
                state = .failed(.other("Could not initialize the local destination directory: \(error)"))
                return false
            }
            return true
        }
    }

    /// A whole CloudKit album is planned only after the reconcile in
    /// `prepareDestination`, so the plan covers every record the server holds. A
    /// surviving checkpoint's progress is merged in, so a resume after every item
    /// verified goes straight to removing the records.
    private func replanFromCloudKitIndex(_ plan: inout MigrationPlan,
                                         source: Album,
                                         planStore: MigrationPlanStore) async -> Bool {
        let existing = await planStore.load()
        let enumerated = await enumerateCloudKitItems(album: source)
        let unsized = enumerated.filter { $0.sizeBytes == 0 }.count
        printDebug("replan from CloudKit index enumerated=\(enumerated.count) unsized=\(unsized) checkpointItems=\(existing?.items.count ?? 0)")
        do {
            plan = try MigrationPlan.album(source,
                                           items: Self.merge(existing: existing?.items ?? plan.items,
                                                             enumerated: enumerated),
                                           createdAt: existing?.createdAt ?? plan.createdAt)
            try await planStore.save(plan)
        } catch {
            printDebug("run ABORT — could not checkpoint the plan: \(error)")
            state = .failed(.other("\(error)"))
            return false
        }
        publishProgress(plan)
        return true
    }

    // MARK: - Run: transfer pass

    /// A whole album moving back to this device removes nothing until every item
    /// has verified: the local album stays invisible here until finalize flips its
    /// storage, so removing a record per item would take it off every other device
    /// while this one cannot show it yet. Everything else removes each source copy
    /// as soon as its destination copy verifies.
    private static func removesSourcePerItem(_ plan: MigrationPlan) -> Bool {
        !(plan.scope == .album && plan.direction == .toLocal)
    }

    /// The main loop: every not-yet-done item through its step. Returns the indices
    /// of the items this run verified — any other `verified` item is checked again
    /// before its source copy is removed — or nil when the run has stopped and
    /// already published its terminal state.
    private func transferItems(_ plan: inout MigrationPlan,
                               step: MigrationItemStep,
                               context: MigrationRunContext,
                               planStore: MigrationPlanStore) async -> Set<Int>? {
        let removesPerItem = Self.removesSourcePerItem(plan)
        let batchSize = ICloudDriveMigrationBatchSize.current
        printDebug("transfer pass BEGIN direction=\(plan.direction) scope=\(plan.scope) removesSourcePerItem=\(removesPerItem) \(Self.stateSummary(plan))")
        defer { printDebug("transfer pass END \(Self.stateSummary(plan))") }
        /// Exclusive upper bound of the item indices already materialized. Only
        /// meaningful for an `.icloud` source; a local album needs no download step.
        var materializedThrough = 0
        var verifiedThisRun = Set<Int>()
        for index in plan.items.indices where !plan.items[index].state.isDone {
            if await mustStopBeforeItem(&plan, context: context, planStore: planStore) { return nil }

            if plan.source.storage == .icloud, index >= materializedThrough {
                materializedThrough = await materializeBatch(startingAt: index,
                                                             in: &plan,
                                                             planStore: planStore,
                                                             sourceModel: context.sourceModel,
                                                             batchSize: batchSize)
                if await honorPendingControl(&plan, planStore: planStore, store: context.store,
                                            sourceModel: context.sourceModel) { return nil }
            }

            publishProgress(plan, currentItemName: plan.items[index].mediaID)
            let entered = plan.items[index].state
            printDebug("item \(index + 1)/\(plan.items.count) BEGIN recordName=\(plan.items[index].recordName) state=\(entered) sizeBytes=\(plan.items[index].sizeBytes)")
            do {
                try await drive(index, in: &plan, step: step, removesSource: removesPerItem, context: context)
            } catch {
                printDebug("item \(index + 1)/\(plan.items.count) ERROR recordName=\(plan.items[index].recordName) error=\(error)")
                if await recordItemError(error, at: index, in: &plan, context: context,
                                         planStore: planStore) { return nil }
            }
            printDebug("item \(index + 1)/\(plan.items.count) END recordName=\(plan.items[index].recordName) \(entered) -> \(plan.items[index].state)")
            if entered != .verified, plan.items[index].state == .verified { verifiedThisRun.insert(index) }
            if plan.scope == .items, plan.items[index].state == .sourceDeleted {
                await recordItemMoved(plan.items[index], of: plan, direction: plan.direction,
                                      source: context.source, destinationModel: context.destinationModel,
                                      destination: context.destination)
            }
            publishProgress(plan, currentItemName: plan.items[index].mediaID)
            await Self.boundaryHook?(.transferred(verified: plan.verifiedCount))
        }
        return verifiedThisRun
    }

    /// Honors an erase's abort-all and any pending pause/cancel before the next item.
    private func mustStopBeforeItem(_ plan: inout MigrationPlan,
                                    context: MigrationRunContext,
                                    planStore: MigrationPlanStore) async -> Bool {
        if Self.abortAllRequested {
            context.store.cancelAll()
            state = .idle
            return true
        }
        return await honorPendingControl(&plan, planStore: planStore, store: context.store,
                                         sourceModel: context.sourceModel)
    }

    /// Records an item's failure. Returns `true` when the error ends the whole run —
    /// a full iCloud, a lost account, or a cancel — with its terminal state published;
    /// any other error fails only the item and the loop moves on.
    private func recordItemError(_ error: Error,
                                 at index: Int,
                                 in plan: inout MigrationPlan,
                                 context: MigrationRunContext,
                                 planStore: MigrationPlanStore) async -> Bool {
        guard let storeError = error as? CloudKitMediaStoreError else {
            plan.markFailed(index, error)
            try? await planStore.save(plan)
            return false
        }
        let unwrapped = Self.unwrapPartial(storeError)
        switch unwrapped {
        case .quotaExceeded:
            plan.markFailed(index, unwrapped)
            try? await planStore.save(plan)
            endRun(.failed(.quota), plan: plan)
            return true
        case .accountUnavailable:
            plan.markFailed(index, unwrapped)
            try? await planStore.save(plan)
            endRun(.failed(.accountUnavailable), plan: plan)
            return true
        case .cancelled:
            plan.revertInFlight()
            evictUnuploadedMaterializedFiles(plan, sourceModel: context.sourceModel)
            if control == .cancelRequested {
                plan.cancelledAt = Date()
                await discardLocalCopiesOfUnmovedItems(&plan, store: context.store)
            }
            try? await planStore.save(plan)
            endRun(.idle, plan: plan)
            return true
        default:
            plan.markFailed(index, unwrapped)
            try? await planStore.save(plan)
            return false
        }
    }

    /// Sets the run's terminal state and publishes the final snapshot with no phase.
    private func endRun(_ terminal: MigrationState, plan: MigrationPlan) {
        state = terminal
        currentPhase = nil
        publishProgress(plan)
    }

    // MARK: - Run: removal pass and finish

    /// For a run that holds source removal until every item has verified, starts that
    /// pass once they have. Returns `false` when the run has stopped and already
    /// published its terminal state.
    private func removeSourcesOnceAllVerified(_ plan: inout MigrationPlan,
                                              step: MigrationItemStep,
                                              context: MigrationRunContext,
                                              verifiedThisRun: Set<Int>,
                                              planStore: MigrationPlanStore) async -> Bool {
        guard !Self.removesSourcePerItem(plan) else { return true }
        guard plan.items.allSatisfy({ $0.state == .verified || $0.state.isDone }),
              plan.items.contains(where: { $0.state == .verified }) else {
            printDebug("removal pass SKIPPED — not every item is verified or done \(Self.stateSummary(plan))")
            return true
        }
        // The last boundary a cancel can stop at: every local copy is verified
        // and no record has been touched, so the album is still whole in CloudKit.
        if await honorPendingControl(&plan, planStore: planStore, store: context.store,
                                    sourceModel: context.sourceModel) { return false }
        return await removeSources(&plan, step: step, context: context, verifiedThisRun: verifiedThisRun,
                                   planStore: planStore, store: context.store)
    }

    /// Settles the run once the item passes are over: finalize when nothing is left,
    /// fail when items failed, otherwise go idle with the checkpoint kept.
    private func finishRun(_ plan: inout MigrationPlan,
                           context: MigrationRunContext,
                           planStore: MigrationPlanStore) async {
        printDebug("finish hasRemainingWork=\(plan.hasRemainingWork) \(Self.stateSummary(plan))")
        if !plan.hasRemainingWork {
            guard await finalize(plan, context: context, planStore: planStore) else { return }
        } else if plan.failedCount > 0 {
            await failWithItemErrors(&plan, store: context.store, planStore: planStore)
        } else {
            state = .idle
        }
        currentPhase = nil
        publishProgress(plan)
    }

    /// Completes a drained plan. Returns `false` when finalizing failed and the run
    /// has already published its terminal state.
    private func finalize(_ plan: MigrationPlan,
                          context: MigrationRunContext,
                          planStore: MigrationPlanStore) async -> Bool {
        switch (plan.scope, plan.direction) {
        case (.album, .toCloudKit):
            return await finalizeAlbumToCloudKit(plan, album: context.source, albumID: context.cloudKitAlbumID,
                                                 planStore: planStore)
        case (.album, .toLocal):
            return await finalizeAlbumToLocal(plan, album: context.source, planStore: planStore)
        case (.items, _):
            await planStore.delete()
            printDebug("run COMPLETED plan=\(plan.id) items=\(plan.items.count)")
            state = .completed
            return true
        }
    }

    /// Flips a drained album's identity back to local. A failure keeps the
    /// checkpoint so the next resume retries the finalize.
    private func finalizeAlbumToLocal(_ plan: MigrationPlan,
                                      album: Album,
                                      planStore: MigrationPlanStore) async -> Bool {
        do {
            _ = try await albumManager.finalizeMigrationToLocal(album: album)
        } catch {
            printDebug("run FINALIZE FAILED album=\(album.name) error=\(error) — checkpoint kept for retry")
            endRun(.failed(.other("Could not finish the album move: \(error)")), plan: plan)
            return false
        }
        await planStore.delete()
        printDebug("run COMPLETED album=\(album.name) -> local items=\(plan.items.count)")
        state = .completed
        return true
    }

    /// Fails the run with the first failed item's error, keeping the checkpoint.
    private func failWithItemErrors(_ plan: inout MigrationPlan,
                                    store: CloudKitMediaStoring,
                                    planStore: MigrationPlanStore) async {
        await discardLocalCopiesOfUnmovedItems(&plan, store: store)
        try? await planStore.save(plan)
        let failedNames = plan.items.filter { $0.state == .failed }.map(\.recordName)
        printDebug("run FAILED plan=\(plan.id) failedCount=\(plan.failedCount) of \(plan.items.count) recordNames=\(failedNames)")
        let firstError = plan.items.first(where: { $0.state == .failed })?.lastError
        state = .failed(.other(firstError.map { "\(plan.failedCount) item(s) failed: \($0)" }
                               ?? "\(plan.failedCount) item(s) failed"))
    }

    /// One item through its step: transfer, then remove the source once verified.
    /// A removal that finds a stale verification resets the item to `pending`; it is
    /// re-driven in place once, since the loop is single-pass and would otherwise end
    /// the run as a silent `.idle` (which the launcher reports as a user cancel). If
    /// it comes back `pending` AGAIN (the record keeps vanishing), that is a failure.
    private func drive(_ index: Int,
                       in plan: inout MigrationPlan,
                       step: MigrationItemStep,
                       removesSource: Bool,
                       context: MigrationRunContext) async throws {
        for _ in 0..<2 {
            let entered = plan.items[index].state
            try await step.transfer(at: index, in: &plan, context: context)
            if removesSource, plan.items[index].state == .verified {
                await Self.boundaryHook?(.removingSource(removed: plan.items.filter { $0.state == .sourceDeleted }.count))
                try await step.removeSource(at: index, in: &plan,
                                            verifiedThisRun: entered != .verified,
                                            context: context)
            }
            guard plan.items[index].state == .pending else { return }
        }
        plan.markFailed(index, MigrationError.verificationFailed(recordName: plan.items[index].recordName))
        try? await context.savePlan(plan)
    }

    /// The second pass of a whole album moving back to this device: removes the
    /// record of every verified item. A cancel is ignored from here on — stopping
    /// part-way would leave the album half-deleted in CloudKit while it still reads
    /// as a CloudKit album here — but a pause still stops at an item boundary, and
    /// the resume comes straight back to this pass. Returns `false` when the run has
    /// already published its terminal state.
    private func removeSources(_ plan: inout MigrationPlan,
                               step: MigrationItemStep,
                               context: MigrationRunContext,
                               verifiedThisRun: Set<Int>,
                               planStore: MigrationPlanStore,
                               store: CloudKitMediaStoring) async -> Bool {
        isRemovingSources = true
        defer { isRemovingSources = false }
        let toRemove = plan.items.indices.filter { plan.items[$0].state == .verified }
        printDebug("removal pass BEGIN removing \(toRemove.count) record(s) \(Self.stateSummary(plan))")
        defer { printDebug("removal pass END \(Self.stateSummary(plan))") }
        setPhase(.removingRemoteCopy, plan: plan)
        var removed = 0
        for index in toRemove where plan.items[index].state == .verified {
            await Self.boundaryHook?(.removing(removed: removed))
            removed += 1
            printDebug("remove \(removed)/\(toRemove.count) recordName=\(plan.items[index].recordName) verifiedThisRun=\(verifiedThisRun.contains(index))")
            if Self.abortAllRequested {
                store.cancelAll()
                state = .idle
                return false
            }
            if control == .pauseRequested,
               await honorPendingControl(&plan, planStore: planStore, store: store) { return false }
            publishProgress(plan, currentItemName: plan.items[index].mediaID)
            do {
                try await step.removeSource(at: index, in: &plan,
                                            verifiedThisRun: verifiedThisRun.contains(index), context: context)
                // A stale local copy sends the item back for another download.
                if plan.items[index].state == .pending {
                    printDebug("remove \(removed)/\(toRemove.count) recordName=\(plan.items[index].recordName) — stale local copy, downloading again")
                    try await drive(index, in: &plan, step: step, removesSource: true, context: context)
                }
                // The step moved the item without this loop republishing; do it
                // here so the ring and "Removing X of Y" advance per record.
                publishProgress(plan, currentItemName: plan.items[index].mediaID)
            } catch {
                // The item stays `verified`, so the resume comes straight back here
                // rather than downloading it again.
                plan.items[index].lastError = "\(error)"
                try? await planStore.save(plan)
                printDebug("run REMOVE FAILED recordName=\(plan.items[index].recordName) error=\(error)")
                if let storeError = error as? CloudKitMediaStoreError,
                   case .accountUnavailable = Self.unwrapPartial(storeError) {
                    state = .failed(.accountUnavailable)
                } else {
                    state = .failed(.other("Could not remove the iCloud copy: \(error)"))
                }
                currentPhase = nil
                publishProgress(plan)
                return false
            }
        }
        return true
    }

    /// Creates the destination's album record before any media is uploaded into it.
    /// Every EncMedia record sets `parent` to its EncAlbum, and CloudKit rejects a
    /// save whose parent is not on the server (`CKError.referenceViolation`), so
    /// without this every upload would fail the same way. `saveAlbum` is idempotent.
    ///
    /// An album this device already holds as a CloudKit album is saved from its
    /// `album.json`. Otherwise the record takes the album's name ciphertext byte for
    /// byte and, for a whole album, the hidden flag and cover of the source album.
    private func saveAlbumRecord(for album: Album,
                                 source: Album,
                                 albumID: String,
                                 store: CloudKitMediaStoring,
                                 scope: MigrationScope) async -> Bool {
        let subject = scope == .album ? "This album's" : "The destination album's"
        guard let albumFingerprint = CloudKitKeyStamp.provenAlbumFingerprint(for: album,
                                                                             keyManager: albumManager.keyManager) else {
            printDebug("run ABORT albumID=\(albumID) — no held key decrypts the album's name")
            failedForMissingKey = true
            state = .failed(.other("\(subject) key is not on this device."))
            return false
        }
        do {
            let upload: CloudKitAlbumUpload
            if let marker = CloudKitAlbumMarker.read(albumID: albumID) {
                upload = CloudKitAlbumUpload(albumID: albumID,
                                             encName: marker.encName,
                                             createdAt: marker.createdAt,
                                             isHidden: marker.isHidden,
                                             keyFingerprint: albumFingerprint,
                                             coverMediaID: marker.recordCoverMediaID)
            } else {
                let settings = scope == .album ? source : album
                let cover = albumManager.getAlbumCoverImageId(album: settings)
                upload = CloudKitAlbumUpload(albumID: albumID,
                                             encName: album.encryptedPathComponent,
                                             createdAt: album.creationDate,
                                             isHidden: albumManager.isAlbumHidden(settings),
                                             keyFingerprint: albumFingerprint,
                                             coverMediaID: cover == CloudKitAlbumMarker.disabledCoverID ? nil : cover)
            }
            try await store.saveAlbum(upload)
            printDebug("run album record ready albumID=\(albumID)")
            return true
        } catch {
            printDebug("run ABORT saveAlbum FAILED albumID=\(albumID) error=\(error)")
            if case .underlying(let underlying) = Self.unwrapPartial(mapCKError(error)),
               let ckError = underlying as? CKError, ckError.code == .invalidArguments {
                // "Cannot create new type EncAlbum in production schema" — the
                // Production environment never got the schema deploy. Distinct
                // reason so the alert is actionable instead of "Partial failure".
                state = .failed(.schemaNotDeployed)
            } else {
                let target = scope == .album ? "the album" : "the destination album"
                state = .failed(.other("Could not create \(target) in iCloud: \(error)"))
            }
            return false
        }
    }

    /// Keeps both albums' indexes current as an item-scope move lands each item, and
    /// tells the gallery. Once every component of the item has left the source, a
    /// source album whose cover it was falls back to its default cover. An album-scope
    /// move needs none of this: finalize flips the whole album at once.
    private func recordItemMoved(_ item: MigrationItem,
                                 of plan: MigrationPlan,
                                 direction: MigrationDirection,
                                 source: Album,
                                 destinationModel: DataStorageModel?,
                                 destination: Album) async {
        if plan.items.allSatisfy({ $0.mediaID != item.mediaID || $0.state == .sourceDeleted }) {
            albumManager.resetAlbumCover(album: source, ifItIs: item.mediaID)
        }
        switch direction {
        case .toCloudKit:
            await removeFromSourceIndex(item, source: source)
        case .toLocal:
            let entry = MediaIndexEntry(
                id: item.mediaID,
                hasPhotoComponent: item.mediaType == .photo,
                hasVideoComponent: item.mediaType == .video,
                dateEncrypted: nil,
                dateTaken: item.createdAt,
                subtypeRawValue: 0
            )
            _ = try? await MediaIndexStore(album: destination).upsert([entry])
            guard let destinationModel else { return }
            let url = destinationModel.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
            FileOperationBus.shared.didCreate(EncryptedMedia(source: .url(url), mediaType: item.mediaType, id: item.mediaID))
        }
    }

    /// Clears the moved component from the source index. A Live Photo keeps its
    /// entry, and its place in the grid, until its other component has moved too;
    /// only then is the grid told it is gone.
    private func removeFromSourceIndex(_ item: MigrationItem, source: Album) async {
        guard let entryRemoved = try? await MediaIndexStore(album: source).removeComponent(recordName: item.recordName),
              entryRemoved else { return }
        let media = EncryptedMedia(source: .url(URL(fileURLWithPath: "/dev/null")),
                                   mediaType: item.mediaType, id: item.mediaID)
        FileOperationBus.shared.didDelete([media])
    }

    /// Clears the source index component of every item an earlier run finished
    /// moving to CloudKit. A run killed between an item's `sourceDeleted` checkpoint
    /// and its index write leaves the entry naming a file that is gone.
    private func removeLeftoverSourceEntries(of plan: MigrationPlan, source: Album) async {
        guard let entries = await MediaIndexStore(album: source).current()?.entries else { return }
        for item in plan.items where item.state == .sourceDeleted {
            guard let entry = entries.first(where: { $0.id == item.mediaID }),
                  item.mediaType == .photo ? entry.hasPhotoComponent : entry.hasVideoComponent else { continue }
            printDebug("run clearing leftover source entry recordName=\(item.recordName)")
            await removeFromSourceIndex(item, source: source)
        }
    }

    /// Flips a drained album's identity to CloudKit. Returns `false` when the run
    /// already published its terminal state and must return without publishing again.
    private func finalizeAlbumToCloudKit(_ plan: MigrationPlan,
                                         album: Album,
                                         albumID: String,
                                         planStore: MigrationPlanStore) async -> Bool {
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
            if CloudKitAlbumMarker.exists(albumID: albumID) {
                await planStore.delete()
                state = .idle
                return true
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
            _ = try albumManager.finalizeMigrationToCloudKit(album: album, albumID: albumID)
        } catch {
            printDebug("run FINALIZE FAILED album=\(album.name) error=\(error) — checkpoint kept for retry")
            state = .failed(.other("Could not finish the album move: \(error)"))
            currentPhase = nil
            publishProgress(plan)
            return false
        }
        try? FileManager.default.removeItem(at: MediaIndexStore.indexURL(for: album))
        await planStore.delete()
        printDebug("run COMPLETED album=\(album.name) items=\(plan.items.count)")
        state = .completed
        return true
    }

    // MARK: - Materialization (iCloud Drive sources)

    /// Downloads the next `batchSize` not-yet-done files back onto the device and
    /// returns the exclusive upper bound of the item indices it covered.
    ///
    /// Failures are recorded as `lastError` and the item is left `pending` — never
    /// marked done here. `LocalToCloudKitStep` owns the skip-versus-fail decision: it is
    /// the one that can tell "the file is genuinely gone" from "the file is still a
    /// placeholder", which is the difference between finishing an album and silently
    /// abandoning someone's photos in iCloud Drive.
    private func materializeBatch(startingAt startIndex: Int,
                                  in plan: inout MigrationPlan,
                                  planStore: MigrationPlanStore,
                                  sourceModel: DataStorageModel?,
                                  batchSize: Int) async -> Int {
        guard let sourceModel else { return startIndex + batchSize }

        var indices: [Int] = []
        var index = startIndex
        while index < plan.items.count, indices.count < batchSize {
            if !plan.items[index].state.isDone { indices.append(index) }
            index += 1
        }
        guard !indices.isEmpty else { return index }

        var urlByIndex: [Int: URL] = [:]
        for i in indices {
            urlByIndex[i] = sourceModel.driveURLForMedia(withID: plan.items[i].mediaID,
                                                         type: plan.items[i].mediaType)
        }

        let snapshot = plan
        setPhase(.materializing, plan: snapshot,
                 currentItemName: plan.items[indices[0]].mediaID)
        let alreadyMaterialized = plan.items
            .map { sourceModel.driveURLForMedia(withID: $0.mediaID, type: $0.mediaType) }
            .filter { ICloudPlaceholderName.isMaterialized($0) }.count
        ICloudDriveMigrationObserver.shared.recordBatch(size: indices.count,
                                                       alreadyMaterialized: alreadyMaterialized)
        printDebug("materializing batch of \(indices.count) starting at index \(startIndex) (batchSize=\(batchSize), alreadyOnDisk=\(alreadyMaterialized))")

        let results = await materializer.materialize(
            Array(urlByIndex.values),
            inAlbumDirectory: sourceModel.baseURL,
            onProgress: { [weak self] fraction in
                guard let self, self.currentPhase == .materializing else { return }
                self.publishProgress(snapshot,
                                     currentItemName: "\(Int(fraction * 100))%")
            })

        for (i, url) in urlByIndex {
            switch results[url] {
            case .success:
                if let size = Self.fileSize(at: url) {
                    plan.items[i].sizeBytes = size
                }
                plan.items[i].lastError = nil
            case .failure(let error):
                plan.items[i].lastError = "\(error)"
                printDebug("materialize FAILED \(url.lastPathComponent) error=\(error)")
            case .none:
                plan.items[i].lastError = "iCloud Drive did not report a result for this file"
            }
        }
        try? await planStore.save(plan)
        return index
    }

    /// Honors a pending pause/cancel request at a safe boundary (between items, or
    /// before the run's first item). Returns `true` when the run must stop; the
    /// plan is checkpointed and the terminal snapshot published in either case.
    /// A cancel is stamped durable (`cancelledAt`) so background auto-resume skips
    /// the plan, while an on-demand resume can still finish it.
    private func honorPendingControl(_ plan: inout MigrationPlan,
                                     planStore: MigrationPlanStore,
                                     store: CloudKitMediaStoring,
                                     sourceModel: DataStorageModel? = nil) async -> Bool {
        switch control {
        case .pauseRequested:
            evictUnuploadedMaterializedFiles(plan, sourceModel: sourceModel)
            state = .paused
            try? await planStore.save(plan)
            currentPhase = nil
            publishProgress(plan)
            return true
        case .cancelRequested:
            store.cancelAll()
            plan.revertInFlight()
            evictUnuploadedMaterializedFiles(plan, sourceModel: sourceModel)
            plan.cancelledAt = Date()
            await discardLocalCopiesOfUnmovedItems(&plan, store: store)
            try? await planStore.save(plan)
            state = .idle
            currentPhase = nil
            publishProgress(plan)
            return true
        case .running:
            return false
        }
    }

    /// An item-scope move back to this device that stops before an item's record is
    /// deleted must not leave a local copy of it as well, or the item shows in both
    /// albums. A copy is discarded only while its record is confirmed on the server,
    /// since otherwise it may be the only one, and the item goes back to download
    /// again on a resume. An album-scope move keeps its copies: that local album is
    /// invisible until finalize, so discarding them would only force a re-download.
    private func discardLocalCopiesOfUnmovedItems(_ plan: inout MigrationPlan,
                                                  store: CloudKitMediaStoring) async {
        guard plan.scope == .items, plan.direction == .toLocal,
              let destination = albums(for: plan)?.destination else { return }
        let model = LocalStorageModel(album: destination)
        for index in plan.items.indices where !plan.items[index].state.isDone {
            let item = plan.items[index]
            let url = model.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard (try? await store.fetchRecordMetadata(recordName: item.recordName)) != nil else {
                printDebug("kept local copy recordName=\(item.recordName) — its record could not be confirmed in CloudKit")
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                printDebug("could not discard local copy recordName=\(item.recordName) error=\(error)")
                continue
            }
            if plan.items[index].state != .failed { plan.items[index].state = .pending }
            printDebug("discarded local copy recordName=\(item.recordName) — the move stopped with its record still in CloudKit")
        }
    }

    /// Pushes back to iCloud the files this run downloaded but never got to upload.
    /// Called AFTER `revertInFlight`, so an aborted upload counts as unuploaded.
    private func evictUnuploadedMaterializedFiles(_ plan: MigrationPlan,
                                                  sourceModel: DataStorageModel?) {
        guard plan.source.storage == .icloud, let sourceModel else { return }
        let urls = plan.items
            .filter { $0.state == .pending || $0.state == .failed }
            .map { sourceModel.driveURLForMedia(withID: $0.mediaID, type: $0.mediaType) }
        guard !urls.isEmpty else { return }
        let onDisk = urls.filter { ICloudPlaceholderName.isMaterialized($0) }.count
        let evicted = materializer.evict(urls)
        printDebug("evicted \(evicted.count) of \(onDisk) materialized-but-unuploaded file(s) after stop")
        ICloudDriveMigrationObserver.shared.recordEviction(evicted: evicted.count, materializedAtStop: onDisk)
        ICloudDriveMigrationObserver.shared.confirmEviction(of: evicted)
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

    /// Resumes a paused/failed/partial run of `plan` from its on-disk checkpoint.
    public func resume(plan: MigrationPlan) async {
        await start(plan: plan)
    }

    /// Stops the album's migration to CloudKit. See `cancel(plan:)`.
    public func cancel(album: Album) async {
        await cancel(planStore: MigrationPlanStore(album: album))
    }

    /// Stops the run and reverts any in-flight item to `pending`. Nothing verified
    /// has lost its only copy. Aborts a transfer already in flight and records a
    /// durable cancel, so the run is not silently auto-resumed in the background —
    /// but the checkpoint is kept so the user can still resume on demand.
    public func cancel(plan: MigrationPlan) async {
        guard let source = sourceAlbum(for: plan) else {
            control = .cancelRequested
            activeStore?.cancelAll()
            return
        }
        await cancel(planStore: MigrationPlanStore(sourceAlbum: source, planID: plan.id))
    }

    private func cancel(planStore: MigrationPlanStore) async {
        guard !isRemovingSources else {
            printDebug("cancel IGNORED — the album's iCloud copies are already being removed")
            return
        }
        control = .cancelRequested
        activeStore?.cancelAll()                  // abort a transfer already in flight
        guard state != .running else { return }   // a running loop performs the revert itself
        guard var plan = await planStore.load() else { state = .idle; currentPhase = nil; return }
        plan.revertInFlight()
        plan.cancelledAt = Date()
        if let albumID = plan.source.cloudKitAlbumID {
            await discardLocalCopiesOfUnmovedItems(&plan, store: makeStore(albumID))
        }
        try? await planStore.save(plan)
        state = .idle
        currentPhase = nil
        publishProgress(plan)
    }

    /// Unwraps a `.partial` to its underlying per-record error. Migration saves are
    /// single-record operations, so a partial failure carries exactly one error —
    /// the operation's real failure. With several, unwrap only when every record
    /// agrees (e.g. quota fails them all identically); otherwise keep `.partial`.
    static func unwrapPartial(_ error: CloudKitMediaStoreError) -> CloudKitMediaStoreError {
        guard case .partial(let failed) = error, !failed.isEmpty else { return error }
        let mapped = failed.values.map { unwrapPartial(mapCKError($0)) }
        if mapped.count == 1 { return mapped[0] }
        if mapped.allSatisfy({ if case .quotaExceeded = $0 { return true } else { return false } }) {
            return .quotaExceeded
        }
        if mapped.allSatisfy({ if case .accountUnavailable = $0 { return true } else { return false } }) {
            return .accountUnavailable
        }
        return error
    }

    /// A side-effect-free pre-flight estimate (item count + total bytes) for the
    /// warning alert. Unlike `plan(album:)` it does NOT persist a checkpoint, so
    /// merely previewing — then cancelling — never leaves a plan that would
    /// auto-resume on the next launch.
    public func estimate(album: Album) async -> (itemCount: Int, totalBytes: Int64) {
        guard album.storageOption == .local || album.storageOption == .icloud else { return (0, 0) }
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

        var logicalSizes: [String: Int64] = [:]
        if album.storageOption == .icloud, let baseURL = directoryModel?.baseURL {
            logicalSizes = await materializer.logicalSizes(inAlbumDirectory: baseURL)
        }

        var items: [MigrationItem] = []
        for entry in mediaWithMetadata {
            let createdAt = entry.dateTaken ?? entry.dateEncrypted ?? album.creationDate
            for component in entry.media.underlyingMedia {
                let url = directoryModel?.driveURLForMedia(withID: component.id, type: component.mediaType)
                let size: Int64
                if let url, album.storageOption == .icloud {
                    size = ICloudPlaceholderName.isMaterialized(url)
                        ? (Self.fileSize(at: url) ?? logicalSizes[url.lastPathComponent] ?? 0)
                        : (logicalSizes[url.lastPathComponent] ?? Self.fileSize(at: url) ?? 0)
                } else {
                    size = url.flatMap(Self.fileSize(at:)) ?? 0
                }
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

    /// Reads every record of a CloudKit album from its synced index into a fresh
    /// `pending` work item, sized from the size sidecar. Live Photos contribute one
    /// item per component (each is a record).
    private func enumerateCloudKitItems(album: Album) async -> [MigrationItem] {
        let entries = await MediaIndexStore(album: album).current()?.entries ?? []
        let sizes = await AlbumSizeSidecar(album: album).sizesByRecordName()
        var items: [MigrationItem] = []
        for entry in entries {
            let createdAt = entry.dateTaken ?? entry.dateEncrypted ?? album.creationDate
            var components: [MediaType] = []
            if entry.hasPhotoComponent { components.append(.photo) }
            if entry.hasVideoComponent { components.append(.video) }
            for type in components {
                let recordName = CloudKitFileAccess.componentRecordName(mediaID: entry.id, type: type)
                items.append(MigrationItem(mediaID: entry.id,
                                           recordName: recordName,
                                           mediaType: type,
                                           createdAt: createdAt,
                                           sizeBytes: sizes[recordName] ?? 0))
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
                result.append(prior)
            } else {
                result.append(fresh)
            }
        }

        for item in existing where !seen.contains(item.recordName)
            && item.state != .pending && item.state != .failed {
            result.append(item)
        }
        return result
    }

    // MARK: - Helpers

    private static func fileSize(at url: URL) -> Int64? {
        url.fileSizeBytes()
    }

    /// One-line count of the plan's items by state, for the run log.
    static func stateSummary(_ plan: MigrationPlan) -> String {
        let counts = Dictionary(grouping: plan.items, by: \.state).mapValues(\.count)
        let states: [MigrationItemState] = [.pending, .uploading, .uploaded, .verified, .sourceDeleted, .failed, .skipped]
        let parts = states.compactMap { state in counts[state].map { "\(state.rawValue)=\($0)" } }
        return "items=\(plan.items.count) [\(parts.joined(separator: " "))]"
    }
}
