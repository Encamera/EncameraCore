//
//  ICloudDriveBlobMigrationPassRunner.swift
//  EncameraCore
//
//  Runs one blob migration pass for one album: moves the media that still lives
//  in the album's linked iCloud Drive folder into CloudKit, one component at a
//  time, through the migration engine's own pieces: the album's iCloud Drive
//  migration plan (written by `ICloudDriveAlbumMigration`),
//  `ICloudDriveMaterializing` for evicted files, and `LocalToCloudKitStep` for
//  the upload and its verification. `ICloudDriveUpgradeScheduler` decides which
//  album's pass runs and when, and records the pause a stopped pass leaves; a
//  pass asks it through `PassControl` whether to stop and reports how it ended
//  as a `PassEnd`, which also says whether only deferred items are left.
//  Nothing here reads the scheduler's state.
//
//  Per item, picked only by `BlobMigrationOrder.next`:
//
//  1. Take the item's `createdAt` from the album's index entry (the date the
//     folder scanner gave it), so the item keeps its place in the grid.
//  2. Materialize the file if it is evicted. A file with unresolved
//     `NSFileVersion` conflicts reads as its current version, the file at its
//     URL.
//  3. Upload it by creating its record and verify the record (the step). No
//     record exists before this upload, so a conflict means another run or
//     another device uploaded it, and that record still has to verify. A large
//     legacy video is re-encrypted to ENC3 on the way.
//  4. Flip the component's index location to `.cloudKit`, so the parity sweep
//     can remove the file later should the delete below not happen.
//  5. Resolve the file's conflict, if it has one, keeping the current version
//     that was uploaded and removing the others (`ICloudDriveFileVersioning`).
//     This drops whatever only another version held, which is accepted: a
//     conflict on an encrypted media file is rare, and the version the album
//     shows is the one that moves. It happens only after the record verified, so
//     an item that fails keeps every version.
//  6. Delete the file through the verified delete (`ICloudDriveComponentDeleting`),
//     which re-checks the record first.
//  7. Checkpoint.
//
//  Each file goes as soon as its item verifies. This flow does not use the
//  whole-album move's rule that no source copy is deleted until every item has
//  verified, and must not be changed to: iCloud Drive and the CloudKit private
//  database draw on the same iCloud quota, so keeping both copies for a migration
//  that runs for days would double the album's footprint and make `quotaExceeded`
//  likely for exactly the users with the largest libraries. Deleting per item
//  keeps the extra space to about one item. The two-pass rule keeps a stopped
//  move's source album whole and visible; here there is no separate source album,
//  only one album whose items are in one of two places.
//
//  Checkpoints: the step saves the plan after each of its transitions and the pass
//  saves `sourceDeleted` after the delete, so a killed run resumes where it was.
//  An item left `verified` goes straight to the verified delete, never uploaded
//  again; one left `uploading` is checked against the server first; one whose file
//  is already gone is done. The plan is read again before each item, so items the
//  album step adds while the pass runs are picked up.
//
//  An item is tried once per pass. One whose delete was refused (size unknown,
//  a failed delete) stays `verified` and a later pass deletes
//  it; one that failed is tried again on a later pass. A pass ends when every item
//  has been tried, and then hands the album to `ICloudDriveAlbumFinish`, which
//  removes the folder, the plan and the link once the album is done.
//
//  No item ends for good while its file is still in the folder. An item that
//  cannot move right now is deferred: it stays `pending` with a
//  `deferralReason` and is retried last (the bottom tier of
//  `BlobMigrationOrder`). It is deferred when its
//  bytes are not readable as encrypted media, when no key on this device opens
//  it (decided only by a pass that started unlocked, so the keys were read from
//  the keychain rather than a cache that may be stale), when its file stayed a
//  placeholder through `maxFailedDownloads` failed downloads, each counted only
//  when the device was still on Wi-Fi after it, or when a record with its name
//  belongs to another album. Its file stays in the folder and its component stays
//  `.iCloudDrive`, so it is still read from iCloud Drive. A retry that moves it
//  clears the reason; one that fails for one of those reasons again keeps the
//  item deferred, and a failed download keeps the reason it had; any other
//  failure fails the item as usual and clears the reason. One whose file is gone
//  by then, because another device moved it, ends done. A deferred item is
//  remaining work, so a pass still takes it up, but not bytes still to move.
//  Network, quota and account errors never defer an item.
//
//  A pass runs with iCloud Drive, a network, Wi-Fi and an iCloud account, in the
//  foreground only, and not in Low Power Mode or a serious or critical thermal
//  state; a condition that fails stops the pass before its next item, before
//  anything is downloaded or uploaded, as does a stop request. It stops for an
//  album whose `album.json` is gone and for a folder whose marker no longer
//  names the album. No `CKOperation` outlives the call that made it. Once an
//  erase has halted the migration the item under way is abandoned where it is,
//  without another checkpoint, index write or delete.
//
//  A full iCloud, no iCloud account or an undeployed Production schema halts the
//  pass with `.paused`, and the item it was on goes back to where it was, not
//  failed; a full iCloud is also recorded on the plan (`lastFailure`), so a pass
//  that starts before `MigrationLastFailure.quotaRetryInterval` has passed stops
//  at once. An item whose transfer CloudKit says to retry while off Wi-Fi goes
//  back to `pending`, keeping its `deferralReason`, and halts the pass with
//  `.waitingForWiFi`. Uploaded blobs go into the blob cache cold, so a migration
//  never evicts media the user opened, except an item migrated because it was
//  viewed, which goes in warm.
//
//  Keys come from `BlobMigrationKeyCache`, never from the keychain while the
//  phone is locked. A pass that starts unlocked reads them into the
//  cache; one that starts locked uses what the cache holds, and with nothing held
//  ends at once without reading the plan or the keychain. While locked, the
//  ordering function offers no encrypting item, so only ciphertext-only items
//  move, and on unlock the same function offers encrypting items first.
//
//  Plaintext is never written while locked, as a check of its own and not only
//  through the ordering: an encrypting item starts only while protected data is
//  available, and one under way when the phone locks
//  (`protectedDataWillBecomeUnavailable`) is abandoned at its next chunk, its
//  scratch directory removed and the item put back to `pending`. The
//  re-encryption scratch files have the default protection class, so plaintext
//  written while locked would be readable by a forensic extraction of the locked
//  phone. Locked work is possible at all only because plan files, the index and
//  iCloud Drive files have the default class too, readable from first unlock
//  until reboot; giving them a stricter class would stop it.
//

import Foundation

@MainActor
final class ICloudDriveBlobMigrationPassRunner: DebugPrintable {
    typealias StopReason = ICloudDriveBlobMigration.StopReason
    typealias PauseReason = ICloudDriveBlobMigration.PauseReason
    typealias MigrationPassReport = ICloudDriveBlobMigration.MigrationPassReport
    typealias MigrationRunOutcome = ICloudDriveBlobMigration.MigrationRunOutcome
    typealias DeviceResourceStateObserver = ICloudDriveBlobMigration.DeviceResourceStateObserver

    private let albumManager: AlbumManaging
    private let makeStore: () -> CloudKitMediaStoring
    private let materializer: ICloudDriveMaterializing
    private let chunkStore: ChunkedBlobStoring?
    private let uploadQueue: CloudKitUploadQueue
    private let makeVerifiedDelete: (CloudKitMediaStoring) -> ICloudDriveComponentDeleting
    private let conditions: ICloudDriveAlbumMigration.MigrationDeviceConditions
    private let deviceState: @MainActor () -> BlobMigrationDeviceState
    private let seed: (_ mediaID: String) -> UInt64
    private let markerConflictVersions: @Sendable (URL) -> [URL]
    private let keyCache: BlobMigrationKeyCache
    private let notificationCenter: NotificationCenter
    private let deviceResourceStateObserver: DeviceResourceStateObserver
    private let blobCache: CloudKitBlobCache
    private let fileVersions: ICloudDriveFileVersioning
    private let maxFailedDownloads: Int
    private let albumFinish: ICloudDriveAlbumFinish

    /// Every dependency arrives resolved; `ICloudDriveBlobMigration.init`
    /// documents each one and supplies the defaults.
    init(albumManager: AlbumManaging,
         makeStore: @escaping () -> CloudKitMediaStoring,
         materializer: ICloudDriveMaterializing,
         chunkStore: ChunkedBlobStoring?,
         uploadQueue: CloudKitUploadQueue,
         makeVerifiedDelete: @escaping (CloudKitMediaStoring) -> ICloudDriveComponentDeleting,
         conditions: ICloudDriveAlbumMigration.MigrationDeviceConditions,
         deviceState: @escaping @MainActor () -> BlobMigrationDeviceState,
         seed: @escaping (_ mediaID: String) -> UInt64,
         markerConflictVersions: @escaping @Sendable (URL) -> [URL],
         keyCache: BlobMigrationKeyCache,
         notificationCenter: NotificationCenter,
         deviceResourceStateObserver: DeviceResourceStateObserver,
         blobCache: CloudKitBlobCache,
         fileVersions: ICloudDriveFileVersioning,
         maxFailedDownloads: Int,
         albumFinish: ICloudDriveAlbumFinish) {
        self.albumManager = albumManager
        self.makeStore = makeStore
        self.materializer = materializer
        self.chunkStore = chunkStore
        self.uploadQueue = uploadQueue
        self.makeVerifiedDelete = makeVerifiedDelete
        self.conditions = conditions
        self.deviceState = deviceState
        self.seed = seed
        self.markerConflictVersions = markerConflictVersions
        self.keyCache = keyCache
        self.notificationCenter = notificationCenter
        self.deviceResourceStateObserver = deviceResourceStateObserver
        self.blobCache = blobCache
        self.fileVersions = fileVersions
        self.maxFailedDownloads = maxFailedDownloads
        self.albumFinish = albumFinish
    }

    /// What a pass asks of, and tells, whoever started it. Each check is read
    /// live, so a stop or an erase lands mid-pass.
    struct PassControl {
        /// Whether an erase halted the blob migration in this process.
        let isHaltedForErase: @Sendable () -> Bool
        /// Whether the pass was asked to stop before its next item.
        let isStopRequested: @MainActor () -> Bool
        /// Forgets the album's pause: an item verified, or nothing is left to try.
        let forgetPause: @MainActor () -> Void
        /// Posts `itemDidFinish` for the album.
        let postItemDidFinish: @MainActor () -> Void
    }

    /// How a pass ended. A pass stopped for a full iCloud also carries the bytes
    /// the album still needs and how long to wait before trying again.
    struct PassEnd {
        let outcome: MigrationRunOutcome
        var bytesStillNeeded: Int64? = nil
        var retryAfter: TimeInterval? = nil
        /// Whether the pass tried every item and every item still to move is
        /// deferred, so another pass now would move nothing.
        var leavesOnlyDeferredItems = false
    }

    /// What every item of a pass runs against, built once before the first item.
    private struct MigrationPassConfiguration {
        let albumID: String
        let folder: URL
        let cloudKitAlbum: Album
        let sourceModel: DataStorageModel
        let planStore: MigrationPlanStore
        let indexStore: MediaIndexStore
        let context: MigrationRunContext
        let verifiedDelete: ICloudDriveComponentDeleting
        /// The key-proof failure of the item under way.
        let keyProofFailure: KeyProofFailure
        /// Whether the pass read this device's keys from the keychain, so a key
        /// missing from them is missing from the device.
        let keysReadFromKeychain: Bool
        let control: PassControl
    }

    private enum MigrationPassPreparation {
        case ready(MigrationPassConfiguration)
        case stopped(StopReason, bytesStillNeeded: Int64? = nil, retryAfter: TimeInterval? = nil)
    }

    /// Runs one pass over the album's plan until no item is left to try or the
    /// pass stops.
    func executeMigrationPass(albumID: String, folder: URL, control: PassControl) async -> PassEnd {
        var report = MigrationPassReport()
        func stopPass(because reason: StopReason, bytesStillNeeded: Int64? = nil,
                      retryAfter: TimeInterval? = nil) -> PassEnd {
            PassEnd(outcome: .stopped(reason, report), bytesStillNeeded: bytesStillNeeded, retryAfter: retryAfter)
        }

        if control.isHaltedForErase() { return stopPass(because: .erased) }
        let startedUnlocked = conditions.isUnlocked()
        let deviceLocked = DeviceLockedFlag()
        let configuration: MigrationPassConfiguration
        switch await prepareMigrationPass(albumID: albumID, folder: folder, startedUnlocked: startedUnlocked,
                                          deviceLocked: deviceLocked, control: control) {
        case .ready(let preparedConfiguration): configuration = preparedConfiguration
        case .stopped(let stopReason, let bytesStillNeeded, let retryAfter):
            return stopPass(because: stopReason, bytesStillNeeded: bytesStillNeeded, retryAfter: retryAfter)
        }
        let lockObserver = notificationCenter.addObserver(forName: AppLifecycleNotification.protectedDataWillBecomeUnavailable,
                                                          object: nil, queue: nil) { _ in
            deviceLocked.markLocked()
        }
        defer { notificationCenter.removeObserver(lockObserver) }
        printDebug("pass start albumID=\(albumID) unlocked=\(startedUnlocked)")

        var triedRecordNames = Set<String>()
        while true {
            if let stopReason = stopReasonBeforeNextItem(albumID: albumID, folder: folder, control: control) { return stopPass(because: stopReason) }
            guard var latestPlan = await configuration.planStore.load() else { return stopPass(because: .noPlan) }
            guard let nextIndex = nextUntriedIndex(in: latestPlan, excluding: triedRecordNames) else { break }
            let nextItem = latestPlan.items[nextIndex]
            triedRecordNames.insert(nextItem.recordName)

            guard canStart(nextItem, deviceLocked: deviceLocked) else {
                printDebug("item WAITING recordName=\(nextItem.recordName) — encrypting, protected data unavailable")
                report.waitingForUnlock.append(nextItem.recordName)
                continue
            }

            configuration.keyProofFailure.reset()
            let itemResult = await migrate(at: nextIndex, in: &latestPlan, configuration: configuration)
            if case .abandoned = itemResult { return stopPass(because: .erased) }
            control.postItemDidFinish()
            switch itemResult {
            case .deleted, .deferred, .deleteFailed:
                // The item verified: the run is making progress again.
                control.forgetPause()
            default:
                break
            }
            if let haltReason = record(itemResult, for: nextItem.recordName, in: &report) {
                guard haltReason == .quota else { return stopPass(because: .paused(haltReason)) }
                let bytes = await bytesStillNeeded(plan: latestPlan, cloudKitAlbum: configuration.cloudKitAlbum,
                                                   indexStore: configuration.indexStore)
                return stopPass(because: .paused(.quota), bytesStillNeeded: bytes,
                                retryAfter: MigrationLastFailure.quotaRetryInterval)
            }
        }
        control.forgetPause()
        // Nothing is left to try: the album is done once its folder can go.
        var leavesOnlyDeferredItems = false
        if let plan = await configuration.planStore.load() {
            await albumFinish.finish(albumID: albumID, folder: folder, plan: plan, cloudKitAlbum: configuration.cloudKitAlbum)
            let itemsStillToMove = plan.items.filter { !$0.state.isDone }
            leavesOnlyDeferredItems = !itemsStillToMove.isEmpty && itemsStillToMove.allSatisfy(\.isDeferred)
        }
        printDebug("pass finished albumID=\(albumID) pauseReason=none deleted=\(report.deleted.count) deferred=\(report.deferred.count) failed=\(report.failed.count) skipped=\(report.skipped.count) deferredItems=\(report.deferredItems.count) waiting=\(report.waitingForUnlock.count) requeued=\(report.requeued.count)")
        return PassEnd(outcome: .finished(report), leavesOnlyDeferredItems: leavesOnlyDeferredItems)
    }

    /// Checks everything a pass needs before its first item and builds what the
    /// items run against. Locked with no key held, it stops before the plan or
    /// the keychain is read.
    private func prepareMigrationPass(albumID: String,
                                      folder: URL,
                                      startedUnlocked: Bool,
                                      deviceLocked: DeviceLockedFlag,
                                      control: PassControl) async -> MigrationPassPreparation {
        if !startedUnlocked, keyCache.album(forAlbumID: albumID) == nil { return .stopped(.locked) }
        if let unmet = await unmetConditionOnceNetworkPathIsKnown() { return .stopped(unmet) }
        if startedUnlocked { keyCache.refreshKeysFromKeychain(using: albumManager) }
        guard CloudKitAlbumMarker.exists(albumID: albumID) else { return .stopped(.albumNotOnDevice) }
        guard let cloudKitAlbum = keyCache.album(forAlbumID: albumID) else {
            // The cache holds only albums with a plan.
            return .stopped(MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: albumID) ? .albumNotOnDevice : .noPlan)
        }
        if let problem = folderProblem(albumID: albumID, folder: folder) { return .stopped(problem) }

        // The folder as an iCloud Drive album, the plan's source.
        let source = ICloudDriveAlbumMigration.linkedFolderAlbum(folder, cloudKitAlbum: cloudKitAlbum)
        let sourceModel = iCloudStorageModel(album: source)
        guard sourceModel.baseURL.standardizedFileURL == folder.standardizedFileURL else {
            return .stopped(.folderNotInContainer)
        }
        let planStore = MigrationPlanStore(iCloudDriveMigrationFrom: cloudKitAlbum, cloudKitAlbumID: albumID)
        guard let startingPlan = await planStore.load() else { return .stopped(.noPlan) }
        let indexStore = albumManager.mediaIndexStore(for: cloudKitAlbum)

        // A full iCloud waits out the retry interval, whichever pass comes next.
        if let failure = startingPlan.lastFailure, failure.category == .quota {
            let waited = deviceResourceStateObserver.now().timeIntervalSince(failure.date)
            if waited < MigrationLastFailure.quotaRetryInterval {
                let bytes = await bytesStillNeeded(plan: startingPlan, cloudKitAlbum: cloudKitAlbum, indexStore: indexStore)
                return .stopped(.paused(.quota), bytesStillNeeded: bytes,
                                retryAfter: MigrationLastFailure.quotaRetryInterval - waited)
            }
        }

        let cloudKitStore = makeStore()
        guard await cloudKitStore.accountAvailable() else { return .stopped(.paused(.accountUnavailable)) }

        var context = makeMigrationRunContext(source: source, sourceModel: sourceModel, cloudKitAlbum: cloudKitAlbum,
                                              albumID: albumID, store: cloudKitStore, planStore: planStore,
                                              deviceLocked: deviceLocked, control: control)
        let keyProofFailure = KeyProofFailure()
        context.noteKeyProofFailure = { keyProofFailure.set($0) }
        return .ready(MigrationPassConfiguration(albumID: albumID,
                                folder: folder,
                                cloudKitAlbum: cloudKitAlbum,
                                sourceModel: sourceModel,
                                planStore: planStore,
                                indexStore: indexStore,
                                context: context,
                                verifiedDelete: makeVerifiedDelete(cloudKitStore),
                                keyProofFailure: keyProofFailure,
                                keysReadFromKeychain: startedUnlocked,
                                control: control))
    }

    /// Why the pass cannot go on to another item, if it cannot.
    private func stopReasonBeforeNextItem(albumID: String, folder: URL, control: PassControl) -> StopReason? {
        if control.isHaltedForErase() { return .erased }
        if control.isStopRequested() { return .stopRequested }
        if let unmet = unmetCondition() { return unmet }
        guard CloudKitAlbumMarker.exists(albumID: albumID) else { return .albumNotOnDevice }
        return folderProblem(albumID: albumID, folder: folder)
    }

    /// The plan index of the first item the ordering offers that this pass has
    /// not tried yet.
    private func nextUntriedIndex(in plan: MigrationPlan, excluding triedRecordNames: Set<String>) -> Int? {
        let orderedItems = BlobMigrationOrder.next(items: plan.items, deviceState: deviceState(), seed: seed)
        guard let nextItem = orderedItems.first(where: { !triedRecordNames.contains($0.recordName) }) else { return nil }
        return plan.items.firstIndex(where: { $0.recordName == nextItem.recordName })
    }

    /// Clears `deviceLocked` for the item about to run, and sets it again when the
    /// phone is locked already. An encrypting item writes plaintext: it starts
    /// only while protected data is available, whatever the ordering offered, and
    /// returns false otherwise.
    private func canStart(_ item: MigrationItem, deviceLocked: DeviceLockedFlag) -> Bool {
        deviceLocked.clear()
        let isUnlocked = conditions.isUnlocked()
        if item.kind == .encrypting { return isUnlocked }
        if !isUnlocked { deviceLocked.markLocked() }
        return true
    }

    /// Adds the item's result to `report`. Returns the run-halting failure when
    /// the item halted the run; that item is not failed.
    private func record(_ itemResult: ItemResult, for recordName: String, in report: inout MigrationPassReport) -> PauseReason? {
        switch itemResult {
        case .deleted: report.deleted.append(recordName)
        case .deferred(let skipReason): report.deferred[recordName] = skipReason
        case .deleteFailed: report.deleteFailed.append(recordName)
        case .failed: report.failed.append(recordName)
        case .skipped: report.skipped.append(recordName)
        case .deferredItem(let reason): report.deferredItems[recordName] = reason
        case .requeued: report.requeued.append(recordName)
        case .halted(let cause): return cause
        case .abandoned: break
        }
        return nil
    }

    /// The album's bytes still on iCloud Drive less the deferred ones.
    private func bytesStillNeeded(plan: MigrationPlan, cloudKitAlbum: Album, indexStore: MediaIndexStore) async -> Int64 {
        let entries = await indexStore.current()?.entries ?? []
        return await albumManager.sizeSidecar(for: cloudKitAlbum)
            .mediaBytes(for: entries, deferred: plan.deferredRecordNames)
            .remainingOnICloudDrive
    }

    private enum ItemResult {
        case deleted
        case deferred(ICloudDriveVerifiedDeleteSkipReason)
        case deleteFailed
        case failed
        case skipped
        case deferredItem(MigrationDeferralReason)
        case requeued
        /// A failure that halts the run; the item is not failed.
        case halted(PauseReason)
        /// An erase halted the migration while the item was under way: nothing
        /// more is written for it.
        case abandoned
    }

    /// One item through materialize, upload, verify, location flip, conflict
    /// resolution and verified delete, checkpointed after every transition. Once
    /// an erase has halted the migration it returns `.abandoned` from wherever it
    /// is, writing nothing more.
    private func migrate(at index: Int, in plan: inout MigrationPlan, configuration: MigrationPassConfiguration) async -> ItemResult {
        let planStore = configuration.planStore
        let item = plan.items[index]
        let url = configuration.sourceModel.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
        printDebug("item BEGIN recordName=\(item.recordName) state=\(item.state)")

        var downloadedHere = false
        if item.state == .pending || item.state == .failed {
            await alignCreatedAt(at: index, in: &plan, indexStore: configuration.indexStore, cloudKitAlbum: configuration.cloudKitAlbum)
            downloadedHere = await materialize(at: index, in: &plan, url: url, folder: configuration.folder)
            if configuration.control.isHaltedForErase() { return .abandoned }
            if ICloudPlaceholderName.existsInAnyForm(url), !ICloudPlaceholderName.isMaterialized(url) {
                if (plan.items[index].failedDownloads ?? 0) >= maxFailedDownloads {
                    return await deferItem(at: index, in: &plan, reason: .neverDownloads, url: url,
                                           downloadedHere: false, planStore: planStore)
                }
                if let reason = item.deferralReason {
                    return await deferItem(at: index, in: &plan, reason: reason, url: url,
                                           downloadedHere: false, planStore: planStore)
                }
            }
            try? await planStore.save(plan)
        }
        // A deferred item's retry: anything but deferring it again clears the
        // reason, which `recordTransferError` restores for a pause or a requeue.
        plan.items[index].deferralReason = nil
        // A file downloaded ahead is evicted again like one downloaded here.
        if ICloudDriveDownloadAhead.isRequested(url) {
            ICloudDriveDownloadAhead.removeRequest(url)
            downloadedHere = true
        }

        do {
            try await LocalToCloudKitStep().transfer(at: index, in: &plan, context: configuration.context)
        } catch {
            if configuration.control.isHaltedForErase() { return .abandoned }
            return await recordTransferError(error, at: index, in: &plan, url: url, deferralReason: item.deferralReason,
                                             downloadedHere: downloadedHere, planStore: planStore)
        }
        if configuration.control.isHaltedForErase() { return .abandoned }

        switch plan.items[index].state {
        case .verified:
            break
        case .skipped:
            return .skipped
        case .pending where plan.items[index].deferralReason == .recordInAnotherAlbum:
            // The step deferred it: another album owns a record with its name.
            if downloadedHere { evict(url) }
            return .deferredItem(.recordInAnotherAlbum)
        case .failed:
            switch configuration.keyProofFailure.value {
            case .unreadable:
                return await deferItem(at: index, in: &plan, reason: .unreadable, url: url,
                                       downloadedHere: downloadedHere, planStore: planStore)
            case .missingKey where configuration.keysReadFromKeychain:
                return await deferItem(at: index, in: &plan, reason: .missingKey, url: url,
                                       downloadedHere: downloadedHere, planStore: planStore)
            default:
                // A deferred item that still cannot prove its key stays deferred.
                if configuration.keyProofFailure.value != nil, let reason = item.deferralReason {
                    return await deferItem(at: index, in: &plan, reason: reason, url: url,
                                           downloadedHere: downloadedHere, planStore: planStore)
                }
                if downloadedHere { evict(url) }
                return .failed
            }
        default:
            if downloadedHere { evict(url) }
            return .failed
        }

        // The item verified, so the run is no longer held off by a full iCloud.
        if plan.lastFailure != nil {
            plan.lastFailure = nil
            try? await planStore.save(plan)
        }

        await flipToCloudKit(plan.items[index], indexStore: configuration.indexStore)
        if configuration.control.isHaltedForErase() { return .abandoned }

        // The current version is the one uploaded and verified; the others go.
        if !fileVersions.unresolvedConflictVersionURLs(of: url).isEmpty {
            do {
                try fileVersions.resolveConflicts(keepingCurrentVersionOf: url)
                printDebug("item conflict resolved recordName=\(item.recordName) — kept the current version")
            } catch {
                printDebug("item conflict resolution FAILED recordName=\(item.recordName) error=\(error)")
                plan.items[index].lastError = "could not resolve the file's conflict: \(error)"
                try? await planStore.save(plan)
                return .deleteFailed
            }
        }

        let outcome = await configuration.verifiedDelete.delete(recordName: item.recordName, albumID: configuration.albumID, folder: configuration.folder)
        if configuration.control.isHaltedForErase() { return .abandoned }
        switch outcome {
        case .deleted, .skipped(.notInFolder):
            plan.items[index].state = .sourceDeleted
            plan.items[index].lastError = nil
            try? await planStore.save(plan)
            printDebug("item deleted recordName=\(item.recordName)")
            return .deleted
        case .skipped(.recordMissing):
            // The record went after it verified: the item uploads again later.
            plan.items[index].state = .pending
            plan.items[index].lastError = "stale verification: record no longer in CloudKit"
            try? await planStore.save(plan)
            return .failed
        case .skipped(.wrongAlbum):
            plan.items[index].lastError = "a record with this name belongs to another album"
            return await deferItem(at: index, in: &plan, reason: .recordInAnotherAlbum, url: url,
                                   downloadedHere: downloadedHere, planStore: planStore)
        case .skipped(.sizeMismatch):
            plan.items[index].state = .failed
            plan.items[index].lastError = "the file is not the size of its record"
            try? await planStore.save(plan)
            return .failed
        case .skipped(let reason):
            return .deferred(reason)
        case .failed(let error):
            plan.items[index].lastError = "\(error)"
            try? await planStore.save(plan)
            return .deleteFailed
        }
    }

    /// Defers the item to the last tier: back to `pending` with `reason`, its
    /// file kept on iCloud Drive (evicted again if this pass downloaded it) and
    /// its component left as it is.
    private func deferItem(at index: Int,
                           in plan: inout MigrationPlan,
                           reason: MigrationDeferralReason,
                           url: URL,
                           downloadedHere: Bool,
                           planStore: MigrationPlanStore) async -> ItemResult {
        printDebug("item DEFERRED recordName=\(plan.items[index].recordName) reason=\(reason) lastError=\(plan.items[index].lastError ?? "")")
        plan.items[index].state = .pending
        plan.items[index].deferralReason = reason
        try? await planStore.save(plan)
        if downloadedHere { evict(url) }
        return .deferredItem(reason)
    }

    /// The run-halting failure `error` is, if any: a full iCloud, no iCloud
    /// account, or an undeployed Production schema.
    static func runHaltingCause(of error: Error) -> PauseReason? {
        let mapped = mapCKError(error)
        switch mapped {
        case .quotaExceeded: return .quota
        case .accountUnavailable: return .accountUnavailable
        default: return mapped.isUndeployedSchema ? .schemaNotDeployed : nil
        }
    }

    /// Records a transfer that threw. A transfer CloudKit says to retry
    /// (`networkUnavailable` and `networkFailure` among them) while the device
    /// is off Wi-Fi lost its Wi-Fi, which is not the item's failure: the item
    /// goes back to `pending` and the run halts with `.waitingForWiFi`. On Wi-Fi
    /// such an error fails the item. A run-halting failure leaves the item where
    /// it was, not failed, and halts the run, a quota failure also being recorded
    /// on the plan; anything else fails the item only. An item put back where it
    /// was gets its `deferralReason` back.
    private func recordTransferError(_ error: Error,
                                     at index: Int,
                                     in plan: inout MigrationPlan,
                                     url: URL,
                                     deferralReason: MigrationDeferralReason?,
                                     downloadedHere: Bool,
                                     planStore: MigrationPlanStore) async -> ItemResult {
        func requeue(_ why: String) async {
            printDebug("item REQUEUED recordName=\(plan.items[index].recordName) — \(why)")
            plan.revertInFlight()
            plan.items[index].state = .pending
            plan.items[index].lastError = nil
            plan.items[index].deferralReason = deferralReason
            try? await planStore.save(plan)
            if downloadedHere { evict(url) }
        }
        if error is MigrationReencryptionAbandoned {
            await requeue("the phone locked during its re-encryption")
            return .requeued
        }
        if mapCKError(error).isRetryable, !conditions.isOnUnmeteredNetwork() {
            await requeue("lost Wi-Fi during its transfer error=\(error)")
            return .halted(.waitingForWiFi)
        }
        printDebug("item ERROR recordName=\(plan.items[index].recordName) error=\(error)")
        plan.revertInFlight()
        if let cause = Self.runHaltingCause(of: error) {
            plan.items[index].lastError = "\(mapCKError(error))"
            plan.items[index].deferralReason = deferralReason
            if cause == .quota {
                plan.lastFailure = MigrationLastFailure(category: .quota, date: deviceResourceStateObserver.now())
            }
            try? await planStore.save(plan)
            if downloadedHere { evict(url) }
            return .halted(cause)
        }
        plan.markFailed(index, error)
        try? await planStore.save(plan)
        if downloadedHere { evict(url) }
        return .failed
    }

    // MARK: - Item helpers

    /// Sets the item's `createdAt` from its index entry, as the folder scanner
    /// dated it: `dateTaken ?? dateEncrypted`, falling back to the album's
    /// creation date. An item with no entry keeps its planned date.
    private func alignCreatedAt(at index: Int,
                                in plan: inout MigrationPlan,
                                indexStore: MediaIndexStore,
                                cloudKitAlbum: Album) async {
        let mediaID = plan.items[index].mediaID
        guard let entry = await indexStore.current()?.entries.first(where: { $0.id == mediaID }) else { return }
        plan.items[index].createdAt = MigrationItem.createdAt(dateTaken: entry.dateTaken,
                                                              dateEncrypted: entry.dateEncrypted,
                                                              albumCreationDate: cloudKitAlbum.creationDate)
    }

    /// Downloads the item's file when it is evicted. Returns whether this call
    /// downloaded it. A failed download is recorded on the item, which the step
    /// then fails as a placeholder, and counted in `failedDownloads` when the
    /// device is still on Wi-Fi, so a failure for want of it never counts.
    private func materialize(at index: Int, in plan: inout MigrationPlan, url: URL, folder: URL) async -> Bool {
        guard ICloudPlaceholderName.existsInAnyForm(url), !ICloudPlaceholderName.isMaterialized(url) else { return false }
        let results = await materializer.materialize([url], inAlbumDirectory: folder, onProgress: { _ in })
        guard plan.items[index].recordMaterialization(results[url], of: url) else {
            if conditions.isOnUnmeteredNetwork() {
                plan.items[index].failedDownloads = (plan.items[index].failedDownloads ?? 0) + 1
            }
            printDebug("materialize FAILED recordName=\(plan.items[index].recordName) failedDownloads=\(plan.items[index].failedDownloads ?? 0) error=\(plan.items[index].lastError ?? "")")
            return false
        }
        plan.items[index].failedDownloads = nil
        return true
    }

    private func evict(_ url: URL) {
        guard ICloudPlaceholderName.isMaterialized(url) else { return }
        _ = materializer.evict([url])
    }

    /// Moves the item's component to `.cloudKit` in the index, keeping its entry's
    /// dates. An upload that conflicted with an existing record wrote no entry.
    private func flipToCloudKit(_ item: MigrationItem, indexStore: MediaIndexStore) async {
        do {
            try await indexStore.apply { entries in
                guard let position = entries.firstIndex(where: { $0.id == item.mediaID }) else { return }
                let entry = entries[position]
                entries[position] = item.mediaType == .photo ? entry.with(photoLocation: .cloudKit)
                                                             : entry.with(videoLocation: .cloudKit)
            }
        } catch {
            printDebug("index flip FAILED recordName=\(item.recordName) error=\(error)")
        }
    }

    // MARK: - Setup

    /// Being locked is not one: it limits which items run, and the keys are held.
    private func unmetCondition() -> StopReason? {
        guard conditions.hasICloudDrive() else { return .iCloudDriveUnavailable }
        guard !conditions.isInBackground() else { return .inBackground }
        guard conditions.hasNetwork() else { return .offline }
        guard conditions.isOnUnmeteredNetwork() else { return .paused(.waitingForWiFi) }
        if let reason = deviceResourceStateObserver.pauseReason { return .paused(reason) }
        return nil
    }

    /// `unmetCondition()`, except that a network that reads as offline or
    /// metered is read again once `waitForKnownNetworkPath` returns, so a path
    /// not yet delivered after launch neither stops nor pauses the pass.
    private func unmetConditionOnceNetworkPathIsKnown() async -> StopReason? {
        let unmetNow = unmetCondition()
        guard unmetNow == .offline || unmetNow == .paused(.waitingForWiFi) else { return unmetNow }
        await conditions.waitForKnownNetworkPath()
        return unmetCondition()
    }

    private func folderProblem(albumID: String, folder: URL) -> StopReason? {
        let verified = ICloudDriveFolderScanner.verifiedFolder(folder, albumID: albumID,
                                                               markerConflictVersions: markerConflictVersions)
        if case .failure(let skip) = verified { return .folderNotVerified(skip.reason) }
        return nil
    }

    private func makeMigrationRunContext(source: Album,
                                         sourceModel: DataStorageModel,
                                         cloudKitAlbum: Album,
                                         albumID: String,
                                         store: CloudKitMediaStoring,
                                         planStore: MigrationPlanStore,
                                         deviceLocked: DeviceLockedFlag,
                                         control: PassControl) -> MigrationRunContext {
        let isHaltedForErase = control.isHaltedForErase
        // The shared blob cache unless a test passes its own.
        let coordinator = CloudKitMigrationManager.makeIsolatedCoordinator(cloudAlbum: cloudKitAlbum, store: store,
                                                                           albumManager: albumManager, bus: .shared,
                                                                           uploadQueue: uploadQueue, chunkStore: chunkStore,
                                                                           cache: blobCache)
        var context = MigrationRunContext(source: source,
                                          destination: cloudKitAlbum,
                                          sourceModel: sourceModel,
                                          destinationModel: nil,
                                          cloudKitAlbumID: albumID,
                                          coordinator: coordinator,
                                          store: store,
                                          uploadQueue: uploadQueue,
                                          savePlan: { try await planStore.save($0) },
                                          storedKeys: keyCache.storedKeys,
                                          keyManager: albumManager.keyManager,
                                          isCancelRequested: { false },
                                          noteMissingKey: {},
                                          setPhase: { _, _, _ in },
                                          reportTransferProgress: { _, _ in },
                                          shouldStopReencryption: { deviceLocked.wasLocked || isHaltedForErase() },
                                          cacheInsertion: Self.cacheInsertion(for:))
        context.defersRecordsInAnotherAlbum = true
        return context
    }

    /// Cold, so weeks of uploads never evict media the user opened; warm for an
    /// item migrated because it was viewed, which the user just opened.
    static func cacheInsertion(for item: MigrationItem) -> CloudKitBlobCache.Insertion {
        item.priorityRequest?.reason == .viewed ? .warm : .cold
    }
}

/// The key-proof failure of the item under way, if its key could not be proven.
private final class KeyProofFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: CloudKitKeyStamp.Failure?

    var value: CloudKitKeyStamp.Failure? { lock.withLock { failure } }
    func set(_ newValue: CloudKitKeyStamp.Failure) { lock.withLock { failure = newValue } }
    func reset() { lock.withLock { failure = nil } }
}

/// Whether the phone has locked since the flag was last cleared, which the loop
/// does before each item. Stays set after the phone unlocks. Safe from any thread.
private final class DeviceLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var wasLocked: Bool { lock.withLock { value } }
    func markLocked() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
}
