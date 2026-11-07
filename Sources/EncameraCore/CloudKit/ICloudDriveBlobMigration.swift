//
//  ICloudDriveBlobMigration.swift
//  EncameraCore
//
//  Moves the media of a CloudKit album that still lives in its linked iCloud
//  Drive folder into CloudKit, one component at a time, through the migration
//  engine's own pieces: the album's iCloud Drive migration plan (written by
//  `ICloudDriveAlbumMigration`), `ICloudDriveMaterializing` for evicted files,
//  and `LocalToCloudKitStep` for the upload and its verification.
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
//     which re-checks the record and refuses a file that is open.
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
//  Checkpoints: the step saves the plan after each of its transitions and the loop
//  saves `sourceDeleted` after the delete, so a killed run resumes where it was.
//  An item left `verified` goes straight to the verified delete, never uploaded
//  again; one left `uploading` is checked against the server first; one whose file
//  is already gone is done. The plan is read again before each item, so items the
//  album step adds while the loop runs are picked up.
//
//  An item is tried once per pass. One whose delete was refused (size unknown,
//  a failed delete) stays `verified` and a later pass deletes
//  it; one that failed is tried again on a later pass. A pass ends when every item
//  has been tried, and `startMigrationPass(albumID:folder:)` runs one; the album step starts a
//  pass after every run that ends `.prepared`. A pass that ends that way hands the
//  album to `ICloudDriveAlbumFinish`, which removes the folder, the plan and the
//  link once the album is done.
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
//  remaining work, so passes keep being scheduled, but not bytes still to move.
//  Network, quota and account errors never defer an item.
//
//  There is no cancel. Once the album has flipped there is nothing to roll back
//  to, since iCloud Drive is no longer a destination, so the only way the loop
//  stops is a pause. It runs with iCloud Drive, Wi-Fi and an iCloud account, in
//  the foreground or in a background task run (`runBackgroundTaskPasses()`); a
//  condition that fails stops the pass at the next item, and a foreground pass
//  stops once the app is in the background unless a background task run takes it
//  over. It stops for an album whose `album.json` is gone and for a folder whose
//  marker no longer names the album. No `CKOperation` outlives the call that made
//  it. An erase halts it for the rest of the process (`haltForErase()`): the
//  passes in flight stop after their item, and no pass or background task run
//  starts again.
//
//  A full iCloud, no iCloud account or an undeployed Production schema halts the
//  run: the pass stops with `.paused` and the album waits with that reason
//  (`pauseReason(albumID:)`), and the item it was on goes back to where it was, not
//  failed. The album stays fully usable meanwhile; nothing is presented. A quota
//  pause also records the bytes the album still needs (`bytesStillNeeded(albumID:)`)
//  and is recorded on the plan (`lastFailure`), so every pass started before
//  `MigrationLastFailure.quotaRetryInterval` has passed pauses at once, and a pass
//  starts again when it has. An account pause starts a pass again when the
//  account changes. A schema pause is not retried in the process; the next
//  launch's album step starts a pass. Such a pause lasts until an item verifies
//  again, and `pauseStateDidChange` is posted whenever an album is paused,
//  changes reason or resumes. `itemDidFinish` is posted each time a pass has an
//  item's result.
//
//  It runs only on Wi-Fi, iCloud Drive downloads included: "Wi-Fi" is an
//  unmetered path (`NetworkMonitor.isOnUnmeteredNetwork`), so wired Ethernet
//  counts and Personal Hotspot and Low Data Mode don't. Off Wi-Fi a pass stops
//  before its next item with `.paused(.waitingForWiFi)`, or `.offline` with no
//  network at all, before anything is downloaded or uploaded, and a background
//  task run ends without touching an item. An item whose transfer CloudKit says
//  to retry while off Wi-Fi goes back to `pending`, keeping its
//  `deferralReason`, and halts the pass with `.waitingForWiFi`. Either way the
//  album waits with `.waitingForWiFi` (`pauseReason(albumID:)`) and a pass starts
//  again for it once `NetworkMonitor.pathDidChange` reports an unmetered network. Its CloudKit
//  requests run under `networkPolicy`: `.background` (utility QoS) unless it is
//  set to `.speedUp` (user-initiated QoS), both with cellular off. While the user
//  allows cellular (`ICloudDriveBlobMigrationCellularPreference`), any connected network
//  counts as Wi-Fi here, a pass's CloudKit requests may use cellular
//  (`requestPolicy`), and a `.waitingForWiFi` album resumes as soon as the
//  preference turns on; turned off, a pass on cellular stops before its next
//  item. The preference reaches nothing else: the folder walk and the
//  whole-album move keep their Wi-Fi-only stores. It pauses while
//  Low Power Mode is on or the thermal state is serious or critical: the pass
//  stops before its next item with `.paused`, the album waits with its reason
//  (`pauseReason(albumID:)`), and a pass starts again for it once the power or
//  thermal state notification reports the reason gone. Uploaded blobs go into the
//  blob cache cold, so a migration never evicts media the user opened, except an
//  item migrated because it was viewed, which goes in warm.
//
//  Keys come from `BlobMigrationKeyCache`, never from the keychain while the
//  phone is locked. A pass or background task run that starts unlocked reads them into the
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
        /// `pauseStateDidChange` is posted.
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

    /// The pass in flight for each album in this process.
    private static var running: [String: ICloudDriveBlobMigration] = [:]

    /// Whether a pass is running for the album `albumID`.
    public static func isRunning(albumID: String) -> Bool {
        running[albumID] != nil
    }

    /// Asks the pass running for `albumID`, if any, to stop before its next item.
    public static func requestStop(albumID: String) {
        running[albumID]?.requestStop()
    }

    /// Asks the pass running for `albumID`, if any, to stop before its next item,
    /// and returns once it has ended. The item in flight finishes and checkpoints
    /// first.
    public static func stopPass(albumID: String) async {
        guard let pass = running[albumID] else { return }
        pass.requestStop()
        await pass.waitForPassEnd()
    }

    /// The albums whose passes are held by `holdPasses`, with how many holds each.
    private static var holds: [String: Int] = [:]

    /// Stops the pass running for `albumID`, once its item in flight has finished
    /// and checkpointed, and keeps any other from starting until every hold is
    /// released with `releasePasses`. For a write to an item still on iCloud Drive
    /// that a pass must not upload part-way through. Releasing starts nothing.
    public static func holdPasses(albumID: String) async {
        holds[albumID, default: 0] += 1
        await stopPass(albumID: albumID)
    }

    /// Releases one hold `holdPasses` took on `albumID`.
    public static func releasePasses(albumID: String) {
        guard let count = holds[albumID] else { return }
        holds[albumID] = count > 1 ? count - 1 : nil
    }

    /// Asks every pass and background task run in progress in this process to stop before its next
    /// item.
    public static func requestStopAll() {
        for pass in running.values { pass.requestStop() }
        activeBackgroundTaskRun?.requestStop()
    }

    /// Whether an erase halted the blob migration in this process. Once set, no
    /// pass or slice starts again in the process; an erase ends the process.
    public private(set) static var isHaltedForErase = false

    /// Halts the blob migration for an erase: every pass and the slice in flight
    /// are asked to stop and waited out, so the item in flight finishes first, no
    /// pass or slice starts again in the process, every hold is dropped and the
    /// keys held in memory are cleared.
    public static func haltForErase() async {
        isHaltedForErase = true
        activeBackgroundTaskRun?.requestStop()
        let passes = Array(running.values)
        for pass in passes { pass.requestStop() }
        for pass in passes { await pass.waitForPassEnd() }
        for albumID in Array(pausedAlbums.keys) { cancelScheduledResume(albumID: albumID) }
        BlobMigrationKeyCache.shared.clear()
        printDebug("halted for erase passes=\(passes.count)")
    }

    /// Test-only: lifts the erase halt so later tests can run passes.
    static func _testClearEraseHalt() {
        isHaltedForErase = false
    }

    /// Whether any iCloud Drive album migration plan on this device has an item
    /// left to work on, deferred items included. Decrypts nothing.
    public static func hasPendingPlans() -> Bool {
        MigrationPlanFileUtil.contents(of: MigrationPlanFileUtil.iCloudDriveAlbumsDirectory).contains {
            MigrationPlanStore.iCloudDriveMigrationPlanHasRemainingWork(at: MigrationPlanFileUtil.albumPlanURL(in: $0))
        }
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

    /// The background task run in progress in this process, if any.
    private static var activeBackgroundTaskRun: ICloudDriveBlobMigration?

    /// Albums whose pass paused, with the loop that starts it again.
    private static var pausedAlbums: [String: PausedAlbum] = [:]

    private struct PausedAlbum {
        let resumingLoop: ICloudDriveBlobMigration
        let folder: URL
        var reason: PauseReason
        var bytesStillNeeded: Int64?
    }

    /// Posted on the loop's `DeviceResourceStateObserver.notificationCenter`
    /// whenever an album is paused, changes pause reason or resumes.
    /// `userInfo["albumID"]` names it.
    public static let pauseStateDidChange = Notification.Name("ICloudDriveBlobMigration.pauseStateDidChange")

    /// Posted on the loop's `DeviceResourceStateObserver.notificationCenter`
    /// each time a pass has an item's result, whatever it is.
    /// `userInfo["albumID"]` names the album.
    public static let itemDidFinish = Notification.Name("ICloudDriveBlobMigration.itemDidFinish")

    /// Why the loop is waiting to resume the album `albumID`, or nil when it is not.
    /// Held in memory only.
    public static func pauseReason(albumID: String) -> PauseReason? {
        pausedAlbums[albumID]?.reason
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
        guard let album = pausedAlbums[albumID], album.reason == .quota else { return nil }
        return album.bytesStillNeeded
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
    private let linkedFolder: (String) -> URL?
    /// Observes the power and thermal state while this loop has a paused album.
    private let deviceResourceStateObserver: DeviceResourceStateObserver
    private let blobCache: CloudKitBlobCache
    private let fileVersions: ICloudDriveFileVersioning
    private let maxFailedDownloads: Int
    private let albumFinish: ICloudDriveAlbumFinish
    private var stopRequested = false
    /// Whether the pass goes on in the background: set for a background task run's passes.
    private var allowsBackground = false
    /// Resumed when the pass in flight ends.
    private var passEndWaiters: [CheckedContinuation<Void, Never>] = []

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
    ///   - linkedFolder: the iCloud Drive folder an album id is linked to, for a background task run.
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
                linkedFolder: @escaping (String) -> URL? = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID:),
                deviceResourceStateObserver: DeviceResourceStateObserver? = nil,
                blobCache: CloudKitBlobCache? = nil,
                fileVersions: ICloudDriveFileVersioning? = nil,
                maxFailedDownloads: Int = ICloudDriveBlobMigration.defaultMaxFailedDownloads,
                finish: ICloudDriveAlbumFinish? = nil) {
        self.albumManager = albumManager
        self.makeStore = makeStore
        self.materializer = materializer ?? ICloudDriveMaterializer()
        self.chunkStore = chunkStore
        self.uploadQueue = uploadQueue
        self.makeVerifiedDelete = makeVerifiedDelete
        self.conditions = conditions
        self.deviceState = deviceState ?? { BlobMigrationDeviceState(isUnlocked: conditions.isUnlocked()) }
        self.seed = seed
        self.markerConflictVersions = markerConflictVersions
        self.keyCache = keyCache ?? .shared
        self.notificationCenter = notificationCenter
        self.linkedFolder = linkedFolder
        self.deviceResourceStateObserver = deviceResourceStateObserver ?? .current
        self.blobCache = blobCache ?? .shared
        self.fileVersions = fileVersions ?? ICloudDriveFileVersions()
        self.maxFailedDownloads = max(maxFailedDownloads, 1)
        self.albumFinish = finish ?? ICloudDriveAlbumFinish(albumManager: albumManager,
                                                            markerConflictVersions: markerConflictVersions)
    }

    /// The `startBlobMigration` an `ICloudDriveAlbumMigration` is given: starts a
    /// pass for the prepared album with a loop built from these dependencies,
    /// unless one is running already, and returns without waiting for it.
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

    /// Starts a pass for the CloudKit album `albumID` over its linked iCloud Drive
    /// folder, unless one is running or the album links no folder.
    public static func startPass(albumManager: AlbumManaging, albumID: String) async {
        guard let folder = CloudKitAlbumMarker.linkedICloudDriveFolderURL(albumID: albumID) else { return }
        await starter(albumManager: albumManager)(albumID, folder)
    }

    // MARK: - Entry points

    /// Starts a pass for the CloudKit album `albumID` and its iCloud Drive folder
    /// `folder` without waiting for it. Returns false, starting nothing, when a
    /// pass for the album is already running.
    @discardableResult
    public func startMigrationPass(albumID: String, folder: URL) -> Bool {
        guard beginMigrationPass(albumID) else { return false }
        Task { @MainActor in
            defer { endMigrationPass(albumID) }
            _ = await executeMigrationPass(albumID: albumID, folder: folder)
        }
        return true
    }

    /// Runs one pass for the CloudKit album `albumID` and its iCloud Drive folder
    /// `folder`, and returns when it ends.
    public func runMigrationPass(albumID: String, folder: URL) async -> MigrationRunOutcome {
        if Self.isHaltedForErase { return .stopped(.erased, MigrationPassReport()) }
        guard beginMigrationPass(albumID) else { return .alreadyRunning }
        defer { endMigrationPass(albumID) }
        return await executeMigrationPass(albumID: albumID, folder: folder)
    }

    /// What one background task run did.
    public struct BackgroundTaskMigrationReport: Equatable, Sendable {
        /// Whether keys were held in memory when the background task run started.
        public var keysInMemory: Bool
        /// Whether protected data was available when the background task run started.
        public var isUnlocked: Bool
        /// Each album's pass, by album id. A pass already running when the background task run
        /// started, which the background task run let go on in the background, is `.alreadyRunning`.
        public var outcomes: [String: MigrationRunOutcome] = [:]
    }

    /// Runs this loop's share of a background task run: a pass, allowed to go on in the
    /// background, for every album whose keys are held, one at a time. Unlocked,
    /// it first reads the keys of every album with a plan into the cache. Locked
    /// with no keys held, it returns at once without reading a plan or the
    /// keychain. A pass already running for an album (a suspended foreground pass
    /// the background task run resumed) goes on in the background, and the background task run waits for it.
    public func runBackgroundTaskPasses() async -> BackgroundTaskMigrationReport {
        let isUnlocked = conditions.isUnlocked()
        var report = BackgroundTaskMigrationReport(keysInMemory: keyCache.hasKeys, isUnlocked: isUnlocked)
        printDebug("background task run start keysInMemory=\(report.keysInMemory) unlocked=\(isUnlocked)")
        guard !Self.isHaltedForErase else {
            printDebug("background task run exit — halted for erase")
            return report
        }
        guard isUnlocked || report.keysInMemory else {
            printDebug("background task run exit — locked with no keys in memory")
            return report
        }
        if isUnlocked { keyCache.refreshKeysFromKeychain(using: albumManager) }

        Self.activeBackgroundTaskRun = self
        defer { if Self.activeBackgroundTaskRun === self { Self.activeBackgroundTaskRun = nil } }
        stopRequested = false
        for albumID in keyCache.albumIDs {
            guard !stopRequested else { break }
            if let pass = Self.running[albumID] {
                pass.allowsBackground = true
                await pass.waitForPassEnd()
                report.outcomes[albumID] = .alreadyRunning
                continue
            }
            guard let folder = linkedFolder(albumID) else { continue }
            allowsBackground = true
            let outcome = await runMigrationPass(albumID: albumID, folder: folder)
            allowsBackground = false
            report.outcomes[albumID] = outcome
        }
        printDebug("background task run finished keysInMemory=\(report.keysInMemory) unlocked=\(isUnlocked) albums=\(report.outcomes.count)")
        return report
    }

    /// Stops this loop's pass before its next item.
    public func requestStop() {
        stopRequested = true
    }

    private func beginMigrationPass(_ albumID: String) -> Bool {
        guard !Self.isHaltedForErase else {
            printDebug("start skipped albumID=\(albumID) — halted for erase")
            return false
        }
        guard Self.running[albumID] == nil else {
            printDebug("start skipped albumID=\(albumID) — a pass is already running")
            return false
        }
        guard Self.holds[albumID] == nil else {
            printDebug("start skipped albumID=\(albumID) — a write to an item still on iCloud Drive holds passes")
            return false
        }
        Self.running[albumID] = self
        stopRequested = false
        return true
    }

    // MARK: - Pause

    /// Records the album as paused for `reason`. A power or thermal pause ends when
    /// the power and thermal notifications report no reason, an account pause when
    /// the account changes, a Wi-Fi pause when the network changes to an
    /// unmetered one, and a quota pause `retryAfter` seconds from now; each then
    /// starts a pass for the album again. A schema pause is not retried in this
    /// process.
    private func scheduleResume(albumID: String, folder: URL, reason: PauseReason,
                                bytesStillNeeded: Int64? = nil, retryAfter: TimeInterval? = nil) {
        Self.cancelScheduledResume(albumID: albumID, notify: false)
        Self.pausedAlbums[albumID] = PausedAlbum(resumingLoop: self, folder: folder, reason: reason,
                                                 bytesStillNeeded: bytesStillNeeded)
        postPauseStateChange(albumID)
        if reason == .quota, let retryAfter {
            deviceResourceStateObserver.scheduleRetry(retryAfter) { [weak self] in self?.retryQuotaPause(albumID) }
        }
        deviceResourceStateObserver.startObserving { [weak self] change in self?.deviceResourceStateChanged(change) }
    }

    /// Forgets the album's scheduled resume, and removes the resuming loop's
    /// observers once it has no other paused album.
    private static func cancelScheduledResume(albumID: String, notify: Bool = true) {
        guard let loop = pausedAlbums.removeValue(forKey: albumID)?.resumingLoop else { return }
        loop.stopObservingDeviceResourcesIfNothingPaused()
        if notify { loop.postPauseStateChange(albumID) }
    }

    /// Forgets the album's scheduled resume if its pause reason matches.
    private static func cancelPause(albumID: String, where matches: (PauseReason) -> Bool) {
        guard let reason = pausedAlbums[albumID]?.reason, matches(reason) else { return }
        cancelScheduledResume(albumID: albumID)
    }

    /// Forgets any pause of the album `albumID`, whose folder is gone.
    static func forgetPause(albumID: String) {
        cancelScheduledResume(albumID: albumID)
    }

    private func postPauseStateChange(_ albumID: String) {
        deviceResourceStateObserver.notificationCenter.post(name: Self.pauseStateDidChange, object: nil,
                                                            userInfo: ["albumID": albumID])
    }

    private func stopObservingDeviceResourcesIfNothingPaused() {
        guard !Self.pausedAlbums.values.contains(where: { $0.resumingLoop === self }) else { return }
        deviceResourceStateObserver.stopObserving()
    }

    private func deviceResourceStateChanged(_ change: DeviceResourceStateObserver.Change) {
        let albums = Self.pausedAlbums.filter { $0.value.resumingLoop === self }
        for (albumID, album) in albums {
            switch album.reason {
            case .lowPowerMode, .thermalState:
                guard change == .powerOrThermalState else { continue }
                if let reason = deviceResourceStateObserver.pauseReason {
                    if reason != album.reason {
                        Self.pausedAlbums[albumID]?.reason = reason
                        postPauseStateChange(albumID)
                    }
                    continue
                }
                resume(albumID, folder: album.folder, why: "the pause reason cleared")
            case .accountUnavailable:
                guard change == .account else { continue }
                resume(albumID, folder: album.folder, why: "the iCloud account changed")
            case .waitingForWiFi:
                guard change == .network, conditions.isOnUnmeteredNetwork() else { continue }
                resume(albumID, folder: album.folder, why: "Wi-Fi returned")
            case .quota, .schemaNotDeployed:
                continue
            }
        }
    }

    private func retryQuotaPause(_ albumID: String) {
        guard let album = Self.pausedAlbums[albumID], album.resumingLoop === self, album.reason == .quota else { return }
        resume(albumID, folder: album.folder, why: "the quota retry interval passed")
    }

    /// Starts a pass for a paused album. A device-state pause is cancelled first;
    /// any other stays until the pass makes progress or pauses again.
    private func resume(_ albumID: String, folder: URL, why: String) {
        Self.cancelPause(albumID: albumID, where: \.isDeviceState)
        guard !Self.isRunning(albumID: albumID) else { return }
        printDebug("resume albumID=\(albumID) — \(why)")
        startMigrationPass(albumID: albumID, folder: folder)
    }

    private func endMigrationPass(_ albumID: String) {
        Self.running[albumID] = nil
        let waiters = passEndWaiters
        passEndWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForPassEnd() async {
        guard Self.running.values.contains(where: { $0 === self }) else { return }
        await withCheckedContinuation { passEndWaiters.append($0) }
    }

    // MARK: - Pass

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
    }

    private enum MigrationPassPreparation {
        case ready(MigrationPassConfiguration)
        case stopped(StopReason, bytesStillNeeded: Int64? = nil, retryAfter: TimeInterval? = nil)
    }

    private func executeMigrationPass(albumID: String, folder: URL) async -> MigrationRunOutcome {
        var report = MigrationPassReport()
        func stopPass(because reason: StopReason, bytesStillNeeded: Int64? = nil,
                      retryAfter: TimeInterval? = nil) -> MigrationRunOutcome {
            let pauseReason: PauseReason?
            switch reason {
            case .paused(let paused): pauseReason = paused
            case .offline: pauseReason = .waitingForWiFi
            default: pauseReason = nil
            }
            if let pauseReason {
                scheduleResume(albumID: albumID, folder: folder, reason: pauseReason,
                               bytesStillNeeded: bytesStillNeeded, retryAfter: retryAfter)
            } else {
                Self.cancelPause(albumID: albumID) { $0.isDeviceState || $0 == .waitingForWiFi }
            }
            printDebug("pass stopped albumID=\(albumID) reason=\(reason) pauseReason=\(pauseReason.map { "\($0)" } ?? "none") bytesStillNeeded=\(bytesStillNeeded.map(String.init) ?? "-") deleted=\(report.deleted.count) failed=\(report.failed.count) deferredItems=\(report.deferredItems.count)")
            return .stopped(reason, report)
        }

        let startedUnlocked = conditions.isUnlocked()
        let deviceLocked = DeviceLockedFlag()
        let configuration: MigrationPassConfiguration
        switch await prepareMigrationPass(albumID: albumID, folder: folder, startedUnlocked: startedUnlocked,
                                          deviceLocked: deviceLocked) {
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
            if let stopReason = stopReasonBeforeNextItem(albumID: albumID, folder: folder) { return stopPass(because: stopReason) }
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
            deviceResourceStateObserver.notificationCenter.post(name: Self.itemDidFinish, object: nil,
                                                                userInfo: ["albumID": albumID])
            switch itemResult {
            case .deleted, .deferred, .deleteFailed:
                // The item verified: the run is making progress again.
                Self.cancelScheduledResume(albumID: albumID)
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
        Self.cancelScheduledResume(albumID: albumID)
        // Nothing is left to try: the album is done once its folder can go.
        if let plan = await configuration.planStore.load() {
            await albumFinish.finish(albumID: albumID, folder: folder, plan: plan, cloudKitAlbum: configuration.cloudKitAlbum)
        }
        printDebug("pass finished albumID=\(albumID) pauseReason=none deleted=\(report.deleted.count) deferred=\(report.deferred.count) failed=\(report.failed.count) skipped=\(report.skipped.count) deferredItems=\(report.deferredItems.count) waiting=\(report.waitingForUnlock.count) requeued=\(report.requeued.count)")
        return .finished(report)
    }

    /// Checks everything a pass needs before its first item and builds what the
    /// items run against. Locked with no key held, it stops before the plan or
    /// the keychain is read.
    private func prepareMigrationPass(albumID: String,
                                      folder: URL,
                                      startedUnlocked: Bool,
                                      deviceLocked: DeviceLockedFlag) async -> MigrationPassPreparation {
        if !startedUnlocked, keyCache.album(forAlbumID: albumID) == nil { return .stopped(.locked) }
        if let unmet = unmetCondition() { return .stopped(unmet) }
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
                                              deviceLocked: deviceLocked)
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
                                keysReadFromKeychain: startedUnlocked))
    }

    /// Why the pass cannot go on to another item, if it cannot.
    private func stopReasonBeforeNextItem(albumID: String, folder: URL) -> StopReason? {
        if stopRequested { return .stopRequested }
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
    }

    /// One item through materialize, upload, verify, location flip, conflict
    /// resolution and verified delete, checkpointed after every transition.
    private func migrate(at index: Int, in plan: inout MigrationPlan, configuration: MigrationPassConfiguration) async -> ItemResult {
        let planStore = configuration.planStore
        let item = plan.items[index]
        let url = configuration.sourceModel.driveURLForMedia(withID: item.mediaID, type: item.mediaType)
        printDebug("item BEGIN recordName=\(item.recordName) state=\(item.state)")

        var downloadedHere = false
        if item.state == .pending || item.state == .failed {
            await alignCreatedAt(at: index, in: &plan, indexStore: configuration.indexStore, cloudKitAlbum: configuration.cloudKitAlbum)
            downloadedHere = await materialize(at: index, in: &plan, url: url, folder: configuration.folder)
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
            return await recordTransferError(error, at: index, in: &plan, url: url, deferralReason: item.deferralReason,
                                             downloadedHere: downloadedHere, planStore: planStore)
        }

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
        guard allowsBackground || !conditions.isInBackground() else { return .inBackground }
        guard conditions.hasNetwork() else { return .offline }
        guard conditions.isOnUnmeteredNetwork() else { return .paused(.waitingForWiFi) }
        if let reason = deviceResourceStateObserver.pauseReason { return .paused(reason) }
        return nil
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
                                         deviceLocked: DeviceLockedFlag) -> MigrationRunContext {
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
                                          shouldStopReencryption: { deviceLocked.wasLocked },
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
