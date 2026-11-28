//
//  ICloudDriveBlobMigration.swift
//  EncameraCore
//
//  The entry points of the blob migration: the move of a CloudKit album's media
//  out of its linked iCloud Drive folder into CloudKit, one pass per album. This
//  type holds no scheduling state. Its functions forward to
//  `ICloudDriveUpgradeScheduler`, which decides which album's pass runs and
//  when, keeps the albums the user asked to upgrade, records why a stopped
//  album is paused and starts it again; its header has the rules.
//  `ICloudDriveBlobMigrationPassRunner` runs one pass; its header says what a
//  pass does with each item and when it stops.
//
//  A pass starts from `starter`, which `ICloudDriveAlbumMigration` calls after
//  every run that ends `.prepared` and which is the user's request for the
//  album (Start Upgrade on the intro the album's upgrade card opens, a tap on
//  its banner waiting to resume,
//  or the album step the scheduler runs to continue a requested album); from
//  `startPass`, a one-off (the end of an item edit or an item move); and
//  from the resume of a paused album described below. Requested albums are kept
//  across launches and continue by themselves, one at a time
//  (`continueRequestedUpgrades(albumManager:)` at launch, and the scheduler on
//  every return to the foreground); `pauseUpgrade(albumID:)` ends a request.
//  Nothing starts a pass in the background.
//
//  At most one album's pass runs in the process. A request for another album
//  meanwhile makes it wait and counts as started; a second start for a waiting
//  album changes nothing. When the running pass ends, whatever the reason, the
//  album that was asked for first goes next: first in, first out.
//  `isQueued(albumID:)` says whether an album waits, `isActive(albumID:)` is
//  true for it, `isRequested(albumID:)` says whether the user's request for it
//  stands, and `ICloudDriveUpgradeScheduler.stateDidChange` is posted whenever
//  any of that changes.
//
//  `requestStop(albumID:)`, `stopPass(albumID:)` and `holdPasses(albumID:)`
//  stop an album's pass and stop it waiting; `forgetPause(albumID:)` (the album
//  was deleted or is done) and `pauseUpgrade(albumID:)` also end its request,
//  and `haltForErase()` ends every one. A `runMigrationPass` caller awaiting
//  such an album gets `.stopped` with the reason.
//
//  A pass that stops for a reason that stops every album on the device (Low
//  Power Mode, heat, no Wi-Fi, no iCloud account, a full iCloud:
//  `PauseReason.isDeviceWide`) holds the other albums, since the next would only
//  stop for the same reason, or fill the same storage. The hold ends when a
//  pass next starts, normally the paused album's own resume, and the others go
//  on when that pass ends. A pass that stops for its own album's reason (an
//  undeployed schema, a stop request, a failure) hands the turn to the next
//  album.
//
//  There is no cancel. Once the album has flipped there is nothing to roll back
//  to, since iCloud Drive is no longer a destination, so a pass only stops, to
//  start again later. An erase halts the migration for the rest of the process
//  (`haltForErase()`): the passes in flight are cancelled, the item under way is
//  abandoned where it is without another checkpoint, index write or delete, and
//  no pass starts again.
//
//  A full iCloud, no iCloud account or an undeployed Production schema halts the
//  run: the pass stops with `.paused` and the album waits with that reason
//  (`pauseReason(albumID:)`), and the item it was on goes back to where it was, not
//  failed. The album stays fully usable meanwhile; nothing is presented. A quota
//  pause also records the bytes the album still needs (`bytesStillNeeded(albumID:)`)
//  and is recorded on the plan (`lastFailure`), so every pass started before
//  `MigrationLastFailure.quotaRetryInterval` has passed pauses at once, and a pass
//  starts again when it has. An account pause starts a pass again when the
//  account changes. A schema pause is not retried in the process. Such a pause
//  lasts until an item verifies again, and
//  `ICloudDriveUpgradeScheduler.stateDidChange` is posted whenever an album is
//  paused, changes reason or resumes. `itemDidFinish` is posted each time a pass
//  has an item's result.
//
//  A pass runs only on Wi-Fi, iCloud Drive downloads included: "Wi-Fi" is an
//  unmetered path (`NetworkMonitor.isOnUnmeteredNetwork`), so wired Ethernet
//  counts and Personal Hotspot and Low Data Mode don't. A pass that stops off
//  Wi-Fi, or with no network at all, leaves the album waiting with
//  `.waitingForWiFi` (`pauseReason(albumID:)`), and a pass starts again for it
//  once `NetworkMonitor.pathDidChange` reports an unmetered network. A pass's
//  CloudKit requests run under `networkPolicy`: `.background` (utility QoS)
//  unless it is set to `.speedUp` (user-initiated QoS), both with cellular off.
//  While the user allows cellular (`ICloudDriveBlobMigrationCellularPreference`),
//  any connected network counts as Wi-Fi here, a pass's CloudKit requests may
//  use cellular (`requestPolicy`), and a `.waitingForWiFi` album resumes as soon
//  as the preference turns on; turned off, a pass on cellular stops before its
//  next item. The preference reaches nothing else: the folder walk and the
//  whole-album move keep their Wi-Fi-only stores. A pass that stops while Low
//  Power Mode is on or the thermal state is serious or critical leaves the album
//  waiting with that reason, and a pass starts again for it once the power or
//  thermal state notification reports the reason gone.
//

import CloudKit
import Foundation

@MainActor
public final class ICloudDriveBlobMigration: DebugPrintable {

    /// Why a pass stopped before every item was tried.
    public enum StopReason: Equatable, Sendable {
        case stopRequested
        case iCloudDriveUnavailable
        case inBackground
        /// The phone is locked and no key for the album is held in memory.
        case locked
        /// No network at all. The album waits with `.waitingForWiFi`, as it does
        /// on a metered network.
        case offline
        /// This device has no `album.json`, or no key, for the CloudKit album.
        case albumNotOnDevice
        /// The folder's marker does not confirm it belongs to the album.
        case folderNotVerified(ICloudDriveFolderScanSkipReason)
        /// The folder is not where an iCloud Drive album folder of this name lives.
        case folderNotInContainer
        /// The album has no iCloud Drive migration plan.
        case noPlan
        /// The album waits until the reason clears.
        case paused(PauseReason)
        /// An erase halted the blob migration in this process.
        case erased
    }

    /// Why the loop is waiting to resume an album.
    public enum PauseReason: Equatable, Sendable {
        /// Low Power Mode is on.
        case lowPowerMode
        /// The thermal state is serious or critical.
        case thermalState(ProcessInfo.ThermalState)
        /// iCloud is full. `bytesStillNeeded(albumID:)` says how much more the
        /// album needs.
        case quota
        /// No usable iCloud account.
        case accountUnavailable
        /// The server rejected the record shape: the Production schema was never
        /// deployed for a type or field this build writes.
        case schemaNotDeployed
        /// The device has no unmetered network, or no network at all. A pass
        /// starts again when `NetworkMonitor.pathDidChange` reports an unmetered one.
        case waitingForWiFi

        /// Whether the device's power or thermal state caused it, rather than a
        /// failure that halted the run.
        var isDeviceState: Bool {
            switch self {
            case .lowPowerMode, .thermalState: return true
            case .quota, .accountUnavailable, .schemaNotDeployed, .waitingForWiFi: return false
            }
        }

        /// Whether it stops every album on the device, not only the paused one:
        /// a pass that stops for it holds the waiting list.
        var isDeviceWide: Bool {
            switch self {
            case .lowPowerMode, .thermalState, .waitingForWiFi, .accountUnavailable, .quota: return true
            case .schemaNotDeployed: return false
            }
        }
    }

    /// Reads the device state that pauses the loop, reports its changes and the
    /// iCloud account's while observing, and holds the clock a quota pause is
    /// retried by.
    @MainActor
    public final class DeviceResourceStateObserver {
        /// A change `startObserving` reports.
        public enum Change: Equatable, Sendable {
            case powerOrThermalState
            case account
            case network
        }

        private let isLowPowerModeEnabled: () -> Bool
        private let thermalState: () -> ProcessInfo.ThermalState
        /// Where `NSProcessInfoPowerStateDidChange`,
        /// `ProcessInfo.thermalStateDidChangeNotification` and
        /// `accountChangeNotification`, `NetworkMonitor.pathDidChange` and
        /// `ICloudDriveBlobMigrationCellularPreference.didChange` are posted, and where
        /// `ICloudDriveUpgradeScheduler.stateDidChange` and `itemDidFinish` are posted.
        let notificationCenter: NotificationCenter
        /// Posted when the iCloud account changes.
        private let accountChangeNotification: Notification.Name
        let now: () -> Date
        /// Runs `retry` on the main actor once `delay` seconds have passed.
        let scheduleRetry: (_ delay: TimeInterval, _ retry: @escaping @MainActor () -> Void) -> Void
        private var observers: [NSObjectProtocol] = []

        public init(isLowPowerModeEnabled: @escaping () -> Bool,
                    thermalState: @escaping () -> ProcessInfo.ThermalState,
                    notificationCenter: NotificationCenter = .default,
                    accountChangeNotification: Notification.Name = .CKAccountChanged,
                    now: @escaping () -> Date = Date.init,
                    scheduleRetry: @escaping (_ delay: TimeInterval, _ retry: @escaping @MainActor () -> Void) -> Void = DeviceResourceStateObserver.sleepThenRun) {
            self.isLowPowerModeEnabled = isLowPowerModeEnabled
            self.thermalState = thermalState
            self.notificationCenter = notificationCenter
            self.accountChangeNotification = accountChangeNotification
            self.now = now
            self.scheduleRetry = scheduleRetry
        }

        nonisolated public static func sleepThenRun(_ delay: TimeInterval, _ retry: @escaping @MainActor () -> Void) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                retry()
            }
        }

        /// This device's `ProcessInfo`.
        public static var current: DeviceResourceStateObserver {
            DeviceResourceStateObserver(isLowPowerModeEnabled: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                                        thermalState: { ProcessInfo.processInfo.thermalState })
        }

        /// The reason to pause for now, if any. Low Power Mode wins over heat.
        public var pauseReason: PauseReason? {
            if isLowPowerModeEnabled() { return .lowPowerMode }
            let thermal = thermalState()
            if thermal == .serious || thermal == .critical { return .thermalState(thermal) }
            return nil
        }

        /// Calls `onChange` on the main actor for every power, thermal, iCloud
        /// account or network change until `stopObserving()`. Does nothing while already
        /// observing.
        public func startObserving(onChange: @escaping @MainActor @Sendable (Change) -> Void) {
            guard observers.isEmpty else { return }
            let changes: [(Notification.Name, Change)] = [
                (.NSProcessInfoPowerStateDidChange, .powerOrThermalState),
                (ProcessInfo.thermalStateDidChangeNotification, .powerOrThermalState),
                (accountChangeNotification, .account),
                (NetworkMonitor.pathDidChange, .network),
                (ICloudDriveBlobMigrationCellularPreference.didChange, .network)
            ]
            observers = changes.map { name, change in
                notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                    Task { @MainActor in onChange(change) }
                }
            }
        }

        public func stopObserving() {
            for observer in observers { notificationCenter.removeObserver(observer) }
            observers = []
        }

        /// Whether `startObserving` was called and `stopObserving` not since.
        var isObserving: Bool { !observers.isEmpty }
    }

    /// What one pass did, by component record name.
    public struct MigrationPassReport: Equatable, Sendable {
        /// Uploaded, verified and their file deleted, or verified with the file
        /// already gone.
        public var deleted: [String] = []
        /// Verified, but the verified delete kept the file for now.
        public var deferred: [String: ICloudDriveVerifiedDeleteSkipReason] = [:]
        /// Verified, but the verified delete could not finish.
        public var deleteFailed: [String] = []
        /// Not verified this pass: nothing was deleted.
        public var failed: [String] = []
        /// Done without moving: the source is gone.
        public var skipped: [String] = []
        /// Deferred to the last tier this pass, with why. They stay on iCloud
        /// Drive.
        public var deferredItems: [String: MigrationDeferralReason] = [:]
        /// Encrypting items left `pending` because protected data was unavailable
        /// when they came up.
        public var waitingForUnlock: [String] = []
        /// Encrypting items abandoned when the phone locked and put back to
        /// `pending`. An item whose transfer lost Wi-Fi halts the pass instead.
        public var requeued: [String] = []

        public init() {}
    }

    public enum MigrationRunOutcome: Equatable, Sendable {
        /// Every eligible item was tried.
        case finished(MigrationPassReport)
        /// The pass stopped early.
        case stopped(StopReason, MigrationPassReport)
        /// A pass for the album is already running in this process.
        case alreadyRunning
    }

    /// Decides which album's pass runs and which wait.
    private static var scheduler: ICloudDriveUpgradeScheduler { .shared }

    /// Whether a pass is running for the album `albumID`.
    public static func isRunning(albumID: String) -> Bool {
        scheduler.isRunning(albumID: albumID)
    }

    /// Asks the pass running for `albumID`, if any, to stop before its next item,
    /// and takes the album off the waiting list.
    public static func requestStop(albumID: String) {
        scheduler.requestStop(albumID: albumID)
    }

    /// Asks the pass running for `albumID`, if any, to stop before its next item,
    /// and returns once it has ended. The item in flight finishes and checkpoints
    /// first. Takes the album off the waiting list.
    public static func stopPass(albumID: String) async {
        scheduler.requestStop(albumID: albumID)
        // An erase already cancelled every pass and does not wait for one.
        guard !isHaltedForErase else { return }
        await scheduler.awaitPassEnd(albumID: albumID)
    }

    /// Stops the pass running for `albumID`, once its item in flight has finished
    /// and checkpointed, and keeps any other from starting until every hold is
    /// released with `releasePasses`. For a write to an item still on iCloud Drive
    /// that a pass must not upload part-way through. The album leaves the waiting
    /// list, and the next waiting album takes the turn. Releasing starts nothing.
    public static func holdPasses(albumID: String) async {
        scheduler.takeItemWriteHold(albumID: albumID)
        // An erase already cancelled every pass and does not wait for one.
        guard !isHaltedForErase else { return }
        await scheduler.awaitPassEnd(albumID: albumID)
    }

    /// Releases one hold `holdPasses` took on `albumID`.
    public static func releasePasses(albumID: String) {
        scheduler.releaseItemWriteHold(albumID: albumID)
    }

    nonisolated private static let eraseHaltLock = NSLock()
    nonisolated(unsafe) private static var haltedForErase = false

    /// Whether an erase halted the blob migration in this process. Once set, no
    /// pass starts again in the process; an erase ends the process.
    nonisolated public static var isHaltedForErase: Bool {
        eraseHaltLock.withLock { haltedForErase }
    }

    /// How long `haltForErase()` gives the cancelled passes to end before the
    /// erase goes on without them.
    static var eraseHaltGracePeriod: Duration = .seconds(5)

    /// Halts the blob migration for an erase: every pass in flight
    /// is cancelled, so a download or upload under way is abandoned and its item
    /// writes nothing more, no pass starts again in the process, no album waits
    /// or is requested any longer, the stored list of requested albums is removed
    /// and the keys held in memory are cleared. Waits for the cancelled pass to
    /// end, but no longer than `eraseHaltGracePeriod`.
    public static func haltForErase() async {
        eraseHaltLock.withLock { haltedForErase = true }
        let hadRunningPass = scheduler.hasRunningPass
        scheduler.emptyStateForErase()
        let deadline = ContinuousClock.now + eraseHaltGracePeriod
        while scheduler.hasRunningPass, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        BlobMigrationKeyCache.shared.clear()
        printDebug("halted for erase hadRunningPass=\(hadRunningPass) stillRunning=\(scheduler.hasRunningPass)")
    }

    /// Test-only: lifts the erase halt so later tests can run passes.
    static func _testClearEraseHalt() {
        eraseHaltLock.withLock { haltedForErase = false }
    }

    /// How many items of the CloudKit album `cloudKitAlbum` are deferred and stay
    /// on iCloud Drive for now: "N items can't be moved right now". Zero without
    /// a plan.
    public static func deferredCount(for cloudKitAlbum: Album) async -> Int {
        guard let albumID = cloudKitAlbum.albumID,
              MigrationPlanStore.hasICloudDriveMigrationPlan(cloudKitAlbumID: albumID) else { return 0 }
        let plan = await MigrationPlanStore(iCloudDriveMigrationFrom: cloudKitAlbum, cloudKitAlbumID: albumID).load()
        return plan?.deferredCount ?? 0
    }

    /// Posted on the loop's `DeviceResourceStateObserver.notificationCenter`
    /// each time a pass has an item's result, whatever it is.
    /// `userInfo["albumID"]` names the album.
    public static let itemDidFinish = Notification.Name("ICloudDriveBlobMigration.itemDidFinish")

    /// Whether the album `albumID` is being moved in this process: a pass is
    /// running for it, it is waiting for another album's pass to end, or its pass
    /// paused and the loop is waiting to start it again. False after a launch
    /// until something starts a pass for the album.
    public static func isActive(albumID: String) -> Bool {
        scheduler.isActive(albumID: albumID)
    }

    /// Pauses the album `albumID`'s upgrade at the user's request: it is no
    /// longer continued by itself, at launch or after another album, and its
    /// pass stops once the item in flight has finished and checkpointed. The
    /// album's banner then waits for a tap to resume.
    public static func pauseUpgrade(albumID: String) {
        scheduler.pauseUpgradeAtUserRequest(albumID: albumID)
    }

    /// Whether the user asked for the album `albumID`'s upgrade and it is not
    /// done yet. Kept across launches.
    public static func isRequested(albumID: String) -> Bool {
        scheduler.isRequested(albumID: albumID)
    }

    /// Why the loop is waiting to resume the album `albumID`, or nil when it is not.
    /// Held in memory only.
    public static func pauseReason(albumID: String) -> PauseReason? {
        scheduler.pauseReason(albumID: albumID)
    }

    /// Why the album `albumID` is not moving, as the user sees it: its held
    /// pause, or `.waitingForWiFi` while the device is off Wi-Fi. A launch off
    /// Wi-Fi starts no pass, so no pause is held then.
    public static func shownPauseReason(albumID: String,
                                        isOnUnmeteredNetwork: Bool = ICloudDriveBlobMigrationCellularPreference.permitsTransferNow) -> PauseReason? {
        pauseReason(albumID: albumID) ?? (isOnUnmeteredNetwork ? nil : .waitingForWiFi)
    }

    /// While the album `albumID` is paused with `.quota`, roughly how many more
    /// bytes it needs to finish: its components still on iCloud Drive, from the
    /// size sidecar, less the deferred ones. Nil otherwise.
    public static func bytesStillNeeded(albumID: String) -> Int64? {
        scheduler.bytesStillNeededWhilePausedForQuota(albumID: albumID)
    }

    /// How many failed downloads of an evicted file, each made while the device
    /// was on Wi-Fi, defer its item.
    nonisolated public static let defaultMaxFailedDownloads = 5

    nonisolated private static let networkPolicyLock = NSLock()
    nonisolated(unsafe) private static var currentNetworkPolicy: CloudKitNetworkPolicy = .background

    /// The policy every pass's CloudKit requests run under, read at each request,
    /// so a change reaches a pass under way. `.background` until set.
    nonisolated public static var networkPolicy: CloudKitNetworkPolicy {
        get { networkPolicyLock.withLock { currentNetworkPolicy } }
        set { networkPolicyLock.withLock { currentNetworkPolicy = newValue } }
    }

    /// The policy a pass's CloudKit requests run under: `networkPolicy`'s
    /// quality of service, with cellular on while
    /// `ICloudDriveBlobMigrationCellularPreference` allows it. Read at each request.
    nonisolated public static var requestPolicy: CloudKitNetworkPolicy {
        networkPolicy.allowingCellular(ICloudDriveBlobMigrationCellularPreference.isAllowed)
    }

    /// The store a pass uses by default: requests under `requestPolicy`. A bound
    /// `makeStore` factory is used as it is.
    nonisolated public static func makeDefaultStore() -> CloudKitMediaStoring {
        CloudKitStoreProvider.makeStore("iCloudDriveBlobMigration", networkPolicy: { requestPolicy })
    }

    /// The device state observed for every album started without one of its own.
    private static let deviceResourceStateObserverOfThisDevice: DeviceResourceStateObserver = .current

    /// What the passes this loop starts run with.
    private let passDependencies: ICloudDriveUpgradeScheduler.PassDependencies

    /// - Parameters:
    ///   - makeStore: builds the CloudKit store for a pass.
    ///   - materializer: downloads evicted files.
    ///   - chunkStore: the chunk store ENC3 uploads go through; nil for the live one.
    ///   - makeVerifiedDelete: the delete each verified item's file goes through.
    ///   - conditions: when a pass may go on to its next item.
    ///   - deviceState: the device state the ordering function is given.
    ///   - seed: this device's order within the ordering's encrypting,
    ///     ciphertext-only and deferred tiers.
    ///   - markerConflictVersions: the unresolved conflict versions of a marker file.
    ///   - keyCache: the keys held in memory for locked work; nil for the shared cache.
    ///   - notificationCenter: where `protectedDataWillBecomeUnavailable` is posted.
    ///   - deviceResourceStateObserver: the power and thermal state that pause the loop.
    ///   - blobCache: the cache uploads are stored in; nil for the shared cache.
    ///   - fileVersions: the conflict versions of the folder's media files.
    ///   - maxFailedDownloads: how many failed downloads defer an item.
    ///   - finish: removes the album's folder once a pass leaves nothing to move.
    public init(albumManager: AlbumManaging,
                makeStore: @escaping () -> CloudKitMediaStoring = ICloudDriveBlobMigration.makeDefaultStore,
                materializer: ICloudDriveMaterializing? = nil,
                chunkStore: ChunkedBlobStoring? = nil,
                uploadQueue: CloudKitUploadQueue = .shared,
                makeVerifiedDelete: @escaping (CloudKitMediaStoring) -> ICloudDriveComponentDeleting = { ICloudDriveVerifiedDelete(store: $0) },
                conditions: ICloudDriveAlbumMigration.MigrationDeviceConditions = .device,
                deviceState: (@MainActor () -> BlobMigrationDeviceState)? = nil,
                seed: @escaping (_ mediaID: String) -> UInt64 = BlobMigrationOrder.deviceSeed(),
                markerConflictVersions: @escaping @Sendable (URL) -> [URL] = ICloudDriveAlbumMarkerFile.unresolvedConflictVersionURLs(of:),
                keyCache: BlobMigrationKeyCache? = nil,
                notificationCenter: NotificationCenter = .default,
                deviceResourceStateObserver: DeviceResourceStateObserver? = nil,
                blobCache: CloudKitBlobCache? = nil,
                fileVersions: ICloudDriveFileVersioning? = nil,
                maxFailedDownloads: Int = ICloudDriveBlobMigration.defaultMaxFailedDownloads,
                finish: ICloudDriveAlbumFinish? = nil) {
        let deviceResourceStateObserver = deviceResourceStateObserver ?? Self.deviceResourceStateObserverOfThisDevice
        self.passDependencies = ICloudDriveUpgradeScheduler.PassDependencies(
            albumManager: albumManager,
            makeStore: makeStore,
            materializer: materializer ?? ICloudDriveMaterializer(),
            chunkStore: chunkStore,
            uploadQueue: uploadQueue,
            makeVerifiedDelete: makeVerifiedDelete,
            conditions: conditions,
            deviceState: deviceState ?? { BlobMigrationDeviceState(isUnlocked: conditions.isUnlocked()) },
            seed: seed,
            markerConflictVersions: markerConflictVersions,
            keyCache: keyCache ?? .shared,
            notificationCenter: notificationCenter,
            deviceResourceStateObserver: deviceResourceStateObserver,
            blobCache: blobCache ?? .shared,
            fileVersions: fileVersions ?? ICloudDriveFileVersions(),
            maxFailedDownloads: max(maxFailedDownloads, 1),
            albumFinish: finish ?? ICloudDriveAlbumFinish(albumManager: albumManager,
                                                         markerConflictVersions: markerConflictVersions))
    }

    /// The `startBlobMigration` an `ICloudDriveAlbumMigration` is given: records
    /// the prepared album as requested by the user and starts a pass for it with
    /// a loop built from these dependencies, or puts the album on the waiting
    /// list while another album's pass runs, unless one is running for it
    /// already, and returns without waiting for it.
    public static func starter(albumManager: AlbumManaging,
                               makeStore: @escaping () -> CloudKitMediaStoring = ICloudDriveBlobMigration.makeDefaultStore,
                               materializer: ICloudDriveMaterializing? = nil,
                               chunkStore: ChunkedBlobStoring? = nil,
                               uploadQueue: CloudKitUploadQueue = .shared,
                               seed: @escaping (_ mediaID: String) -> UInt64 = BlobMigrationOrder.deviceSeed()) -> @MainActor (_ albumID: String, _ folder: URL) async -> Void {
        { albumID, folder in
            guard !isRunning(albumID: albumID) else { return }
            ICloudDriveBlobMigration(albumManager: albumManager, makeStore: makeStore, materializer: materializer,
                                     chunkStore: chunkStore, uploadQueue: uploadQueue, seed: seed)
                .startMigrationPass(albumID: albumID, folder: folder)
        }
    }

    /// Starts a one-off pass for the CloudKit album `albumID` over its linked
    /// iCloud Drive folder: it runs if no album's pass is running and does not
    /// record the album as requested. While another album's pass runs it does
    /// nothing, unless the user asked for this album's upgrade before, which
    /// then waits its turn. Does nothing for an album that links no folder.
    public static func startPass(albumManager: AlbumManaging, albumID: String) async {
        guard let folder = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID),
              !isRunning(albumID: albumID) else { return }
        ICloudDriveBlobMigration(albumManager: albumManager)
            .startMigrationPass(albumID: albumID, folder: folder, isUserRequest: false)
    }

    /// Carries on, one album at a time, with the albums the user asked to
    /// upgrade and that are not done: the one asked for first gets the album
    /// step for its linked folder (`ICloudDriveAlbumMigration.run(folder:)`),
    /// which starts its pass, and the next follows when that pass ends. Albums
    /// the user did not ask for are not touched. For a launch, once credentials
    /// are ready; the scheduler does the same on every return to the
    /// foreground. Returns at once: the album step runs at utility priority.
    public static func continueRequestedUpgrades(albumManager: AlbumManaging) {
        scheduler.runAlbumStepForRequestedAlbum = { albumID in
            await runAlbumStep(forRequestedAlbumID: albumID, albumManager: albumManager)
        }
        scheduler.continueRequestedUpgrades()
    }

    /// Runs the album step for the requested album `albumID` and says what it
    /// means for the album. An album that is no longer on this device or links
    /// no folder has nothing to continue. One whose linked folder is gone is
    /// completed here if another device finished it
    /// (`ICloudDriveAlbumFinish.completeAlbumWhoseLinkedFolderIsGone`), and
    /// otherwise left for the next round. Without iCloud Drive the album waits.
    private static func runAlbumStep(forRequestedAlbumID albumID: String,
                                     albumManager: AlbumManaging) async -> ICloudDriveUpgradeScheduler.AlbumStepResult {
        let marker = CloudKitAlbumMarker.read(albumID: albumID)
        if let result = ICloudDriveUpgradeScheduler.AlbumStepResult(whenAlbumIsOnDevice: marker != nil,
                                                                    linksAFolder: marker?.iCloudDriveFolderPath != nil) {
            return result
        }
        guard let folder = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID) else { return .waitsForConditions }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            let finish = ICloudDriveAlbumFinish(albumManager: albumManager)
            let isCompleted = await finish.completeAlbumWhoseLinkedFolderIsGone(
                albumID: albumID, albumFolders: ICloudDriveAlbumFolderWalk.albumFolders())
            return isCompleted ? .nothingToContinue : .cannotContinueThisRound
        }
        let albumStep = ICloudDriveAlbumMigration(albumManager: albumManager,
                                                  startBlobMigration: starter(albumManager: albumManager))
        switch await albumStep.run(folder: folder) {
        case .prepared: return .startedPass
        case .skipped(let skipReason): return ICloudDriveUpgradeScheduler.AlbumStepResult(skipReason: skipReason)
        }
    }

    // MARK: - Entry points

    /// Starts a pass for the CloudKit album `albumID` and its iCloud Drive folder
    /// `folder` without waiting for it. As the user's request (`isUserRequest`)
    /// it records the album as requested and puts it on the waiting list while
    /// another album's pass runs; an album already on the list stays where it
    /// is. As a one-off it runs only if no album's pass is running, unless the
    /// album was requested before. Returns false, starting nothing, when a pass
    /// for the album is already running or may not start.
    @discardableResult
    public func startMigrationPass(albumID: String, folder: URL, isUserRequest: Bool = true) -> Bool {
        Self.scheduler.requestPassStart(albumID: albumID, folder: folder, dependencies: passDependencies,
                                        isUserRequest: isUserRequest) != .refused
    }

    /// Runs one pass for the CloudKit album `albumID` and its iCloud Drive folder
    /// `folder`, as the user's request for it, and returns when it ends. While
    /// another album's pass runs the
    /// album waits on the waiting list first, and its pass runs with this loop's
    /// dependencies when its turn comes; an album taken off the list before then
    /// returns why.
    public func runMigrationPass(albumID: String, folder: URL) async -> MigrationRunOutcome {
        await Self.scheduler.runPassAndAwaitOutcome(albumID: albumID, folder: folder, dependencies: passDependencies)
    }

    /// Whether the album `albumID` is waiting for its turn: for another album's
    /// pass to end, or for a held waiting list to go on.
    public static func isQueued(albumID: String) -> Bool {
        scheduler.isWaiting(albumID: albumID)
    }

    // MARK: - Pause

    /// Forgets the album `albumID`, which is done or was deleted: its pause, its
    /// wait and the user's request for it go, and it no longer holds the other
    /// albums.
    static func forgetPause(albumID: String) {
        scheduler.forgetAlbum(albumID: albumID)
    }
}
