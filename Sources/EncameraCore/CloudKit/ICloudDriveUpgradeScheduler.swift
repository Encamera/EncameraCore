//
//  ICloudDriveUpgradeScheduler.swift
//  EncameraCore
//
//  Decides which album's blob migration pass runs and when. Everything it knows
//  is one value, `SchedulerState`: each album's state (waiting its turn,
//  running, or paused with a reason), the albums the user asked to upgrade in
//  the order they asked (`order`, kept on disk by `RequestedUpgradesStore`), the
//  album whose device-wide pause holds the waiting albums, the albums an item
//  write holds passes for, and whether the app is in the background.
//
//  The state changes in one place only: `nextStateAndEffects(after:in:)`, a pure
//  function from the state and an `Event` to the new state and the `Effect`s to
//  run. It reads no static state, no notification center and no clock, so each
//  rule is written once and can be checked on values alone.
//
//  The rules:
//
//  - A start is the user's request for the album or a one-off. A request puts
//    the album in the order, once, and it stays there through pauses, holds,
//    stops, the background and relaunches, until the album is forgotten (done
//    or deleted), its pass finds no plan or no album on this device or leaves
//    only deferred items, its album step finds nothing to continue, or an
//    erase. A one-off (the end of an item edit or move) never
//    joins the order.
//  - Albums can also join the order without a start (`albumsRequested`),
//    after the albums already in it: the albums a launch finds mid-upgrade on
//    a device that never stored the order. Nothing starts until the requested
//    albums are next continued.
//  - Requested albums continue by themselves, one at a time, at launch
//    (`continueRequested`), on every return to the foreground and whenever a
//    pass ends: the first in the order that waits starts its pass, and one
//    with no state yet gets its album step (`runAlbumStep`), which starts its
//    pass; that album has the turn meanwhile. Each album is continued at most
//    once per round, a round starting at launch and on each return to the
//    foreground, so an album that cannot finish never loops and never blocks
//    the albums behind it. An album step that waits for device conditions ends
//    the round for the albums not started yet.
//  - At most one album runs. A start with the turn free runs at once. With
//    another album running, a requested album waits and a one-off for an album
//    that was not requested is dropped; a second start for a waiting album
//    changes nothing. When the running pass ends, the waiting album that was
//    asked for first starts: first in, first out.
//  - A pass that stops for a reason that stops every album on the device
//    (`PauseReason.isDeviceWide`: Low Power Mode, heat, no Wi-Fi, no iCloud
//    account, a full iCloud) holds the waiting albums: none starts until a
//    pass next starts, normally the paused album's own resume. A start for an
//    album that is not waiting still runs at once. Forgetting the holder, or a
//    resume of it that may not start, lets them go on.
//  - A paused album resumes when its reason clears: the power or thermal state
//    for a device-state pause, an account change, an unmetered network, or the
//    quota retry coming due. A schema pause is not resumed. A device-state pause
//    is forgotten when its album resumes; any other stays with the album while
//    it waits or runs, until the pass makes progress or stops again.
//  - A hold by an item write stops the album's pass, stops it waiting and
//    refuses its start until every hold is released.
//  - A pause by the user takes the album out of the order, stops its pass
//    before its next item and drops its wait and its pause, so nothing starts
//    it again but a new request.
//  - Forgetting an album drops its pause, its wait and its place in the order.
//    An erase drops everything but the pass in flight, which is cancelled, and
//    removes the stored order.
//  - Nothing starts while the app is in the background. Entering it asks the
//    running pass to stop before its next item; waiting albums keep waiting.
//    Returning to the foreground lets a pass still on that item run on, or
//    starts the album that waited longest. A paused album whose reason clears
//    in the background does not start, and no longer holds the others.
//

import Foundation

/// Runs one blob migration pass for one album.
@MainActor
protocol ICloudDriveBlobMigrationPassRunning: AnyObject {
    func executeMigrationPass(albumID: String, folder: URL,
                              control: ICloudDriveBlobMigrationPassRunner.PassControl) async -> ICloudDriveBlobMigrationPassRunner.PassEnd
}

extension ICloudDriveBlobMigrationPassRunner: ICloudDriveBlobMigrationPassRunning {}

@MainActor
public final class ICloudDriveUpgradeScheduler: DebugPrintable {
    public typealias PauseReason = ICloudDriveBlobMigration.PauseReason
    public typealias StopReason = ICloudDriveBlobMigration.StopReason
    public typealias MigrationPassReport = ICloudDriveBlobMigration.MigrationPassReport
    public typealias MigrationRunOutcome = ICloudDriveBlobMigration.MigrationRunOutcome
    public typealias DeviceResourceStateObserver = ICloudDriveBlobMigration.DeviceResourceStateObserver

    /// The one scheduler of the process, whose order is the stored list.
    public static let shared = ICloudDriveUpgradeScheduler(requestedUpgradesStore: RequestedUpgradesStore())

    /// Posted whenever the scheduler's state changes: an album starts, ends or
    /// stops its pass, joins or leaves the waiting list, is paused, changes
    /// pause reason or resumes, takes or loses the hold on the list, and when
    /// a hold by an item write or the background condition changes.
    /// `userInfo[changedAlbumIDsKey]` holds the ids of the albums it changed
    /// for, sorted, which may be none. Posted on the notification center of the
    /// albums' `DeviceResourceStateObserver`, the default one in the app.
    public static let stateDidChange = Notification.Name("ICloudDriveUpgradeScheduler.stateDidChange")

    /// The `userInfo` key of `stateDidChange` for its `[String]` of album ids.
    public static let changedAlbumIDsKey = "albumIDs"

    /// What an album's pass runs with.
    struct PassDependencies {
        /// Runs the pass.
        let passRunner: ICloudDriveBlobMigrationPassRunning
        /// When a pass may go on, and whether the app is in the background.
        let conditions: ICloudDriveAlbumMigration.MigrationDeviceConditions
        /// The device state that pauses the album, and where its notifications
        /// are posted.
        let deviceResourceStateObserver: DeviceResourceStateObserver

        init(passRunner: ICloudDriveBlobMigrationPassRunning,
             conditions: ICloudDriveAlbumMigration.MigrationDeviceConditions,
             deviceResourceStateObserver: DeviceResourceStateObserver) {
            self.passRunner = passRunner
            self.conditions = conditions
            self.deviceResourceStateObserver = deviceResourceStateObserver
        }

        /// Builds the pass runner from the dependencies
        /// `ICloudDriveBlobMigration.init` documents, each one resolved.
        @MainActor
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
            self.init(passRunner: ICloudDriveBlobMigrationPassRunner(
                          albumManager: albumManager,
                          makeStore: makeStore,
                          materializer: materializer,
                          chunkStore: chunkStore,
                          uploadQueue: uploadQueue,
                          makeVerifiedDelete: makeVerifiedDelete,
                          conditions: conditions,
                          deviceState: deviceState,
                          seed: seed,
                          markerConflictVersions: markerConflictVersions,
                          keyCache: keyCache,
                          notificationCenter: notificationCenter,
                          deviceResourceStateObserver: deviceResourceStateObserver,
                          blobCache: blobCache,
                          fileVersions: fileVersions,
                          maxFailedDownloads: maxFailedDownloads,
                          albumFinish: albumFinish),
                      conditions: conditions,
                      deviceResourceStateObserver: deviceResourceStateObserver)
        }
    }

    /// What became of a request to start a pass.
    enum PassStartResult: Equatable {
        /// The album has the turn and its pass is starting.
        case started
        /// Another album runs, or the list is held: the album waits.
        case queued
        /// Nothing starts: an erase, a hold by an item write, or a pass already
        /// running for the album.
        case refused
    }

    /// The pass in flight.
    private struct RunningPass {
        let albumID: String
        let task: Task<Void, Never>
        /// The `runPassAndAwaitOutcome` call that started it, whose cancellation
        /// cancels it.
        let startedByCall: UUID?
    }

    private(set) var state = SchedulerState()
    /// What each album's pass runs with, from the album's latest start, for
    /// every album in the state.
    private var passDependencies: [String: PassDependencies] = [:]
    /// The device states observed for the albums that have a pause, each with
    /// the albums it is observed for.
    private var observedDeviceStates: [ObjectIdentifier: DeviceResourceStateObserver] = [:]
    private var runningPass: RunningPass?
    /// Why the pass in flight was asked to stop before its next item, if it was.
    private var reasonRunningPassWasAskedToStop: StopReason?
    /// Callers awaiting the outcome of an album's pass, by album id.
    private var passOutcomeWaiters: [String: [CheckedContinuation<MigrationRunOutcome, Never>]] = [:]
    /// Callers awaiting the end of an album's pass, by album id.
    private var passEndWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// The `runPassAndAwaitOutcome` call whose request is being applied.
    private var callStartingPass: UUID?

    /// Whether protected data can be read. Nothing is continued while it cannot.
    var isUnlocked: @MainActor () -> Bool = { ProtectedDataAvailability.isAvailable }
    /// Runs the album step for the requested album `albumID`'s linked folder,
    /// which starts its pass, and returns how it ended. Nil until the app
    /// supplies it; requested albums are not continued meanwhile.
    var runAlbumStepForRequestedAlbum: (@MainActor (_ albumID: String) async -> AlbumStepResult)?

    private let lifecycleNotificationCenter: NotificationCenter
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Where `state.order` is kept across launches; nil keeps it in memory only.
    private let requestedUpgradesStore: RequestedUpgradesStore?

    /// - Parameters:
    ///   - lifecycleNotificationCenter: where
    ///     `AppLifecycleNotification.didEnterBackground` and
    ///     `willEnterForeground` are posted.
    ///   - requestedUpgradesStore: the stored list, read into the order here
    ///     and saved whenever the order changes; nil for none.
    init(lifecycleNotificationCenter: NotificationCenter = .default,
         requestedUpgradesStore: RequestedUpgradesStore? = nil) {
        self.lifecycleNotificationCenter = lifecycleNotificationCenter
        self.requestedUpgradesStore = requestedUpgradesStore
        state.order = requestedUpgradesStore?.loadAlbumIDs() ?? []
        observeAppLifecycle()
    }

    deinit {
        for observer in lifecycleObservers { lifecycleNotificationCenter.removeObserver(observer) }
    }

    // MARK: - Reads

    /// Whether a pass is running for the album `albumID`.
    func isRunning(albumID: String) -> Bool {
        state.albums[albumID]?.isRunning == true
    }

    /// Whether the album `albumID` is waiting for its turn.
    func isWaiting(albumID: String) -> Bool {
        state.albums[albumID]?.isWaiting == true
    }

    /// Whether any album's pass is running.
    var hasRunningPass: Bool {
        state.runningAlbumID != nil
    }

    /// Whether the album `albumID` is running, waiting or paused. An album
    /// whose pass is stopping because the user paused it is not.
    func isActive(albumID: String) -> Bool {
        state.albums[albumID] != nil && state.albumIDStoppingAtUserRequest != albumID
    }

    /// Whether the user asked for the album `albumID`'s upgrade and it is not
    /// done: it is in the order.
    func isRequested(albumID: String) -> Bool {
        state.order.contains(albumID)
    }

    /// Why the album `albumID` is waiting to resume, or nil when it is not.
    func pauseReason(albumID: String) -> PauseReason? {
        state.albums[albumID]?.pause?.reason
    }

    /// While the album `albumID` is paused for a full iCloud, roughly how many
    /// more bytes it needs.
    func bytesStillNeededWhilePausedForQuota(albumID: String) -> Int64? {
        guard let pause = state.albums[albumID]?.pause, pause.reason == .quota else { return nil }
        return pause.bytesStillNeeded
    }

    // MARK: - Starting passes

    /// Starts a pass for the album `albumID` over `folder` without waiting for
    /// it. A user's request records the album as requested and makes it wait
    /// while another album's pass runs; a one-off waits only if the album was
    /// requested before, and is otherwise refused then. An album already
    /// waiting stays where it is, and keeps the dependencies it waits with
    /// unless `replacingWaitingDependencies`.
    @discardableResult
    func requestPassStart(albumID: String, folder: URL, dependencies: PassDependencies,
                          isUserRequest: Bool = true,
                          replacingWaitingDependencies: Bool = false) -> PassStartResult {
        guard !ICloudDriveBlobMigration.isHaltedForErase else {
            printDebug("start skipped albumID=\(albumID) — halted for erase")
            return .refused
        }
        guard !isRunning(albumID: albumID) else {
            printDebug("start skipped albumID=\(albumID) — a pass is already running")
            return .refused
        }
        guard state.itemWriteHolds[albumID] == nil else {
            printDebug("start skipped albumID=\(albumID) — a write to an item still on iCloud Drive holds passes")
            return .refused
        }
        guard !state.isInBackground else {
            printDebug("start skipped albumID=\(albumID) — the app is in the background")
            return .refused
        }
        if !isWaiting(albumID: albumID) || replacingWaitingDependencies {
            passDependencies[albumID] = dependencies
        }
        applyEvent(.passStartRequested(albumID: albumID, folder: folder, isUserRequest: isUserRequest))
        if isRunning(albumID: albumID) { return .started }
        if isWaiting(albumID: albumID) {
            printDebug("start queued albumID=\(albumID) waiting=\(Self.waitingAlbumIDsInStartOrder(in: state).count)")
            return .queued
        }
        return .refused
    }

    /// Runs one pass for the album `albumID` over `folder`, as the user's
    /// request for it, and returns how it ended. While another album's pass
    /// runs the album waits first, with these dependencies; an album that
    /// stops waiting before its turn returns why. Cancelling the caller cancels
    /// a pass this call started.
    func runPassAndAwaitOutcome(albumID: String, folder: URL, dependencies: PassDependencies) async -> MigrationRunOutcome {
        if ICloudDriveBlobMigration.isHaltedForErase { return .stopped(.erased, MigrationPassReport()) }
        if state.isInBackground { return .stopped(.inBackground, MigrationPassReport()) }
        let call = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                callStartingPass = call
                let result = requestPassStart(albumID: albumID, folder: folder, dependencies: dependencies,
                                              replacingWaitingDependencies: true)
                callStartingPass = nil
                switch result {
                case .started, .queued: passOutcomeWaiters[albumID, default: []].append(continuation)
                case .refused: continuation.resume(returning: .alreadyRunning)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRunningPass(startedByCall: call) }
        }
    }

    /// Whether the scheduler keeps its order on disk and no list was ever saved
    /// there: the device ran no build that writes the list, or an erase removed
    /// it. False for a scheduler that keeps its order in memory only.
    var hasNoStoredRequestedList: Bool {
        requestedUpgradesStore.map { !$0.fileExists } ?? false
    }

    /// Adds `albumIDs` to the requested albums, after the ones already there and
    /// in the given order, skipping any already requested. Starts nothing:
    /// `continueRequestedUpgrades()` carries them on.
    func requestAlbums(_ albumIDs: [String]) {
        applyEvent(.albumsRequested(albumIDs: albumIDs))
    }

    /// Carries on with the albums the user asked to upgrade, one at a time: the
    /// one asked for first gets its album step, which starts its pass, and the
    /// next follows when that pass ends. Does nothing while a pass runs, the
    /// list is held, the phone is locked or the app is in the background. Does
    /// not wait for the album step.
    func continueRequestedUpgrades() {
        guard isUnlocked() else { return }
        applyEvent(.continueRequested)
    }

    // MARK: - Stopping passes

    /// Asks the pass running for `albumID`, if any, to stop before its next
    /// item, and takes the album off the list.
    func requestStop(albumID: String) {
        applyEvent(.stopRequested(albumID: albumID))
    }

    /// Returns once no pass is running for `albumID`.
    func awaitPassEnd(albumID: String) async {
        guard isRunning(albumID: albumID) else { return }
        await withCheckedContinuation { passEndWaiters[albumID, default: []].append($0) }
    }

    /// Pauses the album `albumID`'s upgrade because the user asked: it leaves
    /// the requested albums, so it is not continued by itself, its pass is
    /// asked to stop before its next item, and it no longer waits or holds the
    /// other albums. A new request for it starts it again.
    func pauseUpgradeAtUserRequest(albumID: String) {
        applyEvent(.userPaused(albumID: albumID))
    }

    /// Forgets the album `albumID`, which was deleted or is done: its pause and
    /// its place in line go, and its hold on the list ends.
    func forgetAlbum(albumID: String) {
        applyEvent(.albumForgotten(albumID: albumID))
    }

    /// Takes a hold on the passes of the album `albumID` for an item write: its
    /// pass is asked to stop, it leaves the list and no start is accepted until
    /// every hold is released.
    func takeItemWriteHold(albumID: String) {
        applyEvent(.holdTaken(albumID: albumID))
    }

    /// Releases one hold `takeItemWriteHold` took. Starts nothing.
    func releaseItemWriteHold(albumID: String) {
        applyEvent(.holdReleased(albumID: albumID))
    }

    /// Empties the list and cancels the pass in flight for an erase.
    func emptyStateForErase() {
        applyEvent(.erased)
    }

    private func cancelRunningPass(startedByCall call: UUID) {
        guard let runningPass, runningPass.startedByCall == call else { return }
        runningPass.task.cancel()
    }

    // MARK: - Applying events

    /// Sends `event` through the transition function and runs its effects.
    private func applyEvent(_ event: Event) {
        let transition = Self.nextStateAndEffects(after: event, in: state)
        state = transition.state
        for effect in transition.effects { runEffect(effect) }
        observeDeviceStatesOfPausedAlbums()
        passDependencies = passDependencies.filter { state.albums[$0.key] != nil }
    }

    private func runEffect(_ effect: Effect) {
        switch effect {
        case .startPass(let albumID, let folder):
            launchPass(albumID: albumID, folder: folder)
        case .requestStopOfRunningPass(let albumID, let stopReason):
            guard runningPass?.albumID == albumID, reasonRunningPassWasAskedToStop == nil else { return }
            reasonRunningPassWasAskedToStop = stopReason
        case .withdrawStopOfRunningPass(let albumID, let stopReason):
            guard runningPass?.albumID == albumID, reasonRunningPassWasAskedToStop == stopReason else { return }
            reasonRunningPassWasAskedToStop = nil
        case .cancelRunningPass:
            reasonRunningPassWasAskedToStop = .erased
            runningPass?.task.cancel()
        case .answerAwaitingCallers(let albumID, let outcome):
            printDebug("removed from waiting list albumID=\(albumID) outcome=\(outcome)")
            answerCallersAwaitingOutcome(ofAlbumID: albumID, with: outcome)
        case .scheduleQuotaRetry(let albumID, let delay):
            passDependencies[albumID]?.deviceResourceStateObserver.scheduleRetry(delay) { [weak self] in
                self?.applyEvent(.quotaRetryCameDue(albumID: albumID))
            }
        case .runAlbumStep(let albumID):
            runAlbumStep(forRequestedAlbumID: albumID)
        case .saveRequestedAlbumIDs(let albumIDs):
            do {
                try requestedUpgradesStore?.saveAlbumIDs(albumIDs)
            } catch {
                printDebug("could not save the requested albums count=\(albumIDs.count) error=\(error)")
            }
        case .removeStoredRequestedAlbumIDs:
            do {
                try requestedUpgradesStore?.removeFile()
            } catch {
                printDebug("could not remove the stored requested albums error=\(error)")
            }
        case .postStateDidChange(let albumIDs):
            postStateDidChange(forAlbumIDs: albumIDs)
        }
    }

    /// Posts `stateDidChange` once on each notification center the albums use,
    /// with the albums of that center, and on the default one when it changed
    /// for no album.
    private func postStateDidChange(forAlbumIDs albumIDs: [String]) {
        var albumIDsByCenter: [(center: NotificationCenter, albumIDs: [String])] = []
        for albumID in albumIDs {
            let center = notificationCenter(forAlbumID: albumID)
            if let index = albumIDsByCenter.firstIndex(where: { $0.center === center }) {
                albumIDsByCenter[index].albumIDs.append(albumID)
            } else {
                albumIDsByCenter.append((center, [albumID]))
            }
        }
        if albumIDsByCenter.isEmpty { albumIDsByCenter = [(.default, [])] }
        for (center, albumIDs) in albumIDsByCenter {
            center.post(name: Self.stateDidChange, object: nil, userInfo: [Self.changedAlbumIDsKey: albumIDs])
        }
    }

    /// Runs the album step for a requested album at utility priority, without
    /// waiting for it, and reports how it ended. Locked, or with no album step
    /// to run, it reports at once that the album waits.
    private func runAlbumStep(forRequestedAlbumID albumID: String) {
        guard let runAlbumStep = runAlbumStepForRequestedAlbum, isUnlocked() else {
            applyEvent(.albumStepEnded(albumID: albumID, result: .waitsForConditions))
            return
        }
        printDebug("continue albumID=\(albumID) — running its album step")
        Task(priority: .utility) { @MainActor [weak self] in
            let result = await runAlbumStep(albumID)
            self?.printDebug("continue albumID=\(albumID) album step ended result=\(result)")
            self?.applyEvent(.albumStepEnded(albumID: albumID, result: result))
        }
    }

    /// Where the album's notifications are posted.
    private func notificationCenter(forAlbumID albumID: String) -> NotificationCenter {
        passDependencies[albumID]?.deviceResourceStateObserver.notificationCenter ?? .default
    }

    private func answerCallersAwaitingOutcome(ofAlbumID albumID: String, with outcome: MigrationRunOutcome) {
        for waiter in passOutcomeWaiters.removeValue(forKey: albumID) ?? [] { waiter.resume(returning: outcome) }
    }

    /// Runs the album's pass in a task of its own, which an erase cancels.
    private func launchPass(albumID: String, folder: URL) {
        guard let dependencies = passDependencies[albumID] else { return }
        reasonRunningPassWasAskedToStop = nil
        let notificationCenter = notificationCenter(forAlbumID: albumID)
        let control = ICloudDriveBlobMigrationPassRunner.PassControl(
            isHaltedForErase: { ICloudDriveBlobMigration.isHaltedForErase },
            isStopRequested: { [weak self] in self?.reasonRunningPassWasAskedToStop != nil },
            forgetPause: { [weak self] in self?.applyEvent(.passMadeProgress(albumID: albumID)) },
            postItemDidFinish: {
                notificationCenter.post(name: ICloudDriveBlobMigration.itemDidFinish, object: nil,
                                        userInfo: ["albumID": albumID])
            })
        let passRunner = dependencies.passRunner
        let task = Task { @MainActor in
            let end = await passRunner.executeMigrationPass(albumID: albumID, folder: folder, control: control)
            self.endPass(albumID: albumID, end: end)
        }
        runningPass = RunningPass(albumID: albumID, task: task, startedByCall: callStartingPass)
    }

    /// Records the ended pass, hands the turn on and answers whoever awaited it.
    /// A pass that stopped because it was asked to is reported with the reason
    /// it was asked for. One that found the app in the background itself tells
    /// the scheduler so.
    private func endPass(albumID: String, end: ICloudDriveBlobMigrationPassRunner.PassEnd) {
        var outcome = end.outcome
        if case .stopped(.stopRequested, let report) = outcome, let stopReason = reasonRunningPassWasAskedToStop {
            outcome = .stopped(stopReason, report)
        }
        runningPass = nil
        reasonRunningPassWasAskedToStop = nil
        if case .stopped(.inBackground, _) = end.outcome { applyEvent(.enteredBackground) }
        applyEvent(.passEnded(albumID: albumID,
                              ending: PassEnding(outcome: outcome, bytesStillNeeded: end.bytesStillNeeded,
                                                 retryAfter: end.retryAfter,
                                                 leavesOnlyDeferredItems: end.leavesOnlyDeferredItems)))
        if case .stopped(let stopReason, let report) = outcome {
            printDebug("pass stopped albumID=\(albumID) reason=\(stopReason) pauseReason=\(pauseReason(albumID: albumID).map { "\($0)" } ?? "none") bytesStillNeeded=\(end.bytesStillNeeded.map(String.init) ?? "-") deleted=\(report.deleted.count) failed=\(report.failed.count) deferredItems=\(report.deferredItems.count)")
        }
        for waiter in passEndWaiters.removeValue(forKey: albumID) ?? [] { waiter.resume() }
        answerCallersAwaitingOutcome(ofAlbumID: albumID, with: outcome)
    }

    // MARK: - App lifecycle

    /// Turns the app entering the background and returning to the foreground
    /// into events.
    private func observeAppLifecycle() {
        let events: [(Notification.Name, Event)] = [
            (AppLifecycleNotification.didEnterBackground, .enteredBackground),
            (AppLifecycleNotification.willEnterForeground, .enteredForeground)
        ]
        lifecycleObservers = events.map { name, event in
            lifecycleNotificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.applyEvent(event) }
                } else {
                    Task { @MainActor in self?.applyEvent(event) }
                }
            }
        }
    }

    // MARK: - Device state

    /// Observes the device state of every album that has a pause, and stops
    /// observing one no paused album uses.
    private func observeDeviceStatesOfPausedAlbums() {
        var needed: [ObjectIdentifier: DeviceResourceStateObserver] = [:]
        for (albumID, album) in state.albums where album.pause != nil {
            guard let observer = passDependencies[albumID]?.deviceResourceStateObserver else { continue }
            needed[ObjectIdentifier(observer)] = observer
        }
        for (identifier, observer) in observedDeviceStates where needed[identifier] == nil {
            observer.stopObserving()
        }
        for (identifier, observer) in needed where observedDeviceStates[identifier] == nil {
            observer.startObserving { [weak self, weak observer] change in
                guard let observer else { return }
                self?.deviceStateDidChange(change, reportedBy: observer)
            }
        }
        observedDeviceStates = needed
    }

    /// Tells every album `observer` is observed for about the change, each with
    /// the device's state as its own conditions read it.
    private func deviceStateDidChange(_ change: DeviceResourceStateObserver.Change, reportedBy observer: DeviceResourceStateObserver) {
        let albumIDs = passDependencies.filter { $0.value.deviceResourceStateObserver === observer }.keys.sorted()
        for albumID in albumIDs {
            guard let dependencies = passDependencies[albumID], state.albums[albumID]?.pause != nil else { continue }
            applyEvent(.deviceStateChanged(
                albumID: albumID,
                DeviceStateChange(change: change, devicePauseReason: observer.pauseReason,
                                  isOnUnmeteredNetwork: dependencies.conditions.isOnUnmeteredNetwork())))
        }
    }

    // MARK: - State

    /// Why an album's pass stopped to wait, and for a full iCloud roughly how
    /// many more bytes the album needs.
    struct AlbumPause: Equatable, Sendable {
        var reason: PauseReason
        var bytesStillNeeded: Int64?
    }

    /// Where one album stands. A waiting or running album keeps the pause it
    /// resumed from until its pass makes progress or stops again.
    enum AlbumState: Equatable, Sendable {
        /// Waiting for the running pass to end, or for a held list to go on.
        case waiting(folder: URL, keptPause: AlbumPause?)
        /// Its pass holds the turn.
        case running(folder: URL, keptPause: AlbumPause?)
        /// Its pass stopped and starts again when the reason clears.
        case paused(folder: URL, reason: PauseReason, bytesStillNeeded: Int64?)

        var folder: URL {
            switch self {
            case .waiting(let folder, _), .running(let folder, _), .paused(let folder, _, _): return folder
            }
        }

        var pause: AlbumPause? {
            switch self {
            case .waiting(_, let keptPause), .running(_, let keptPause): return keptPause
            case .paused(_, let reason, let bytesStillNeeded): return AlbumPause(reason: reason, bytesStillNeeded: bytesStillNeeded)
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isWaiting: Bool {
            if case .waiting = self { return true }
            return false
        }
    }

    struct SchedulerState: Equatable, Sendable {
        /// Every album that is waiting, running or paused, by album id.
        var albums: [String: AlbumState] = [:]
        /// The albums the user asked to upgrade, first in first out, whatever
        /// state each is in. Kept across launches by `RequestedUpgradesStore`.
        var order: [String] = []
        /// The album whose device-wide pause holds the list.
        var listHeldBy: String?
        /// How many item writes hold each album's passes.
        var itemWriteHolds: [String: Int] = [:]
        /// Whether the app is in the background.
        var isInBackground = false
        /// The requested album whose album step is running to start its pass.
        /// It has the turn meanwhile.
        var continuingAlbumID: String?
        /// The requested albums that are not continued again in this round:
        /// each got its album step, or its pass ended without finishing it. A
        /// round starts at launch and on every return to the foreground.
        var albumIDsTriedThisRound: Set<String> = []
        /// The requested albums whose album step cannot succeed in this
        /// launch. They stay in the order and are not continued again until
        /// the user asks for them or the next launch.
        var albumIDsSkippedForThisLaunch: Set<String> = []
        /// The running album the user paused: its pass was asked to stop, and
        /// leaves no pause behind when it ends.
        var albumIDStoppingAtUserRequest: String?

        init(albums: [String: AlbumState] = [:], order: [String] = [], listHeldBy: String? = nil,
             itemWriteHolds: [String: Int] = [:], isInBackground: Bool = false) {
            self.albums = albums
            self.order = order
            self.listHeldBy = listHeldBy
            self.itemWriteHolds = itemWriteHolds
            self.isInBackground = isInBackground
        }

        var runningAlbumID: String? {
            albums.first(where: { $0.value.isRunning })?.key
        }
    }

    // MARK: - Events and effects

    /// How a pass ended, with what a full iCloud adds to it.
    struct PassEnding: Equatable, Sendable {
        var outcome: MigrationRunOutcome
        var bytesStillNeeded: Int64?
        var retryAfter: TimeInterval?
        /// Whether the pass tried every item and every item still on iCloud
        /// Drive is deferred, so another pass now would move nothing.
        var leavesOnlyDeferredItems = false
    }

    /// A change the device reported, with the device's state when it did.
    struct DeviceStateChange: Equatable, Sendable {
        var change: DeviceResourceStateObserver.Change
        /// The power or thermal reason to pause for now, if any.
        var devicePauseReason: PauseReason?
        var isOnUnmeteredNetwork: Bool
    }

    /// How the album step run for a requested album ended.
    enum AlbumStepResult: Equatable, Sendable {
        /// It prepared the album and asked for its pass.
        case startedPass
        /// It could not run for a reason that holds for every album and clears
        /// by itself (offline, locked, no account, the background, no iCloud
        /// Drive), or its marker is still downloading: the album is tried again
        /// in the next round, and the albums behind it wait for it.
        case waitsForConditions
        /// It could not prepare this album now, for a reason of the album's own
        /// that may clear: the next album goes on, and this one is tried again
        /// in the next round.
        case cannotContinueThisRound
        /// It cannot prepare this album in this launch: the next album goes on,
        /// and this one stays requested but is not tried again until the user
        /// asks for it or the app launches again.
        case cannotContinueThisLaunch
        /// The album is no longer on this device, links no folder, or its
        /// folder is gone: it leaves the order and the next album goes on.
        case nothingToContinue

        /// What an album step that was skipped for `skipReason` means for the
        /// album.
        init(skipReason: ICloudDriveAlbumMigration.MigrationSkipReason) {
            switch skipReason {
            case .offline, .locked, .accountUnavailable, .inBackground, .iCloudDriveUnavailable, .markerEvicted:
                self = .waitsForConditions
            case .albumNotFound, .recordGone, .deletePending, .noMatchingKey, .markerUnreadable:
                self = .cannotContinueThisLaunch
            case .markerConflicted, .recordNotVisibleYet, .markerChanged, .failed:
                self = .cannotContinueThisRound
            }
        }

        /// `.nothingToContinue` for an album that is not on this device or
        /// links no folder; nil for one that gets its album step.
        init?(whenAlbumIsOnDevice isOnDevice: Bool, linksAFolder: Bool) {
            guard !isOnDevice || !linksAFolder else { return nil }
            self = .nothingToContinue
        }
    }

    enum Event: Equatable, Sendable {
        /// A pass was asked for: by the user, who wants the album upgraded, or
        /// as a one-off that only runs if the turn is free.
        case passStartRequested(albumID: String, folder: URL, isUserRequest: Bool)
        /// The running pass verified an item, or found nothing left to try.
        case passMadeProgress(albumID: String)
        case passEnded(albumID: String, ending: PassEnding)
        /// The album's pass should stop before its next item.
        case stopRequested(albumID: String)
        /// An item write took a hold on the album's passes.
        case holdTaken(albumID: String)
        case holdReleased(albumID: String)
        /// The album was deleted or is done.
        case albumForgotten(albumID: String)
        /// The user paused the album's upgrade: it is no longer requested.
        case userPaused(albumID: String)
        case erased
        case enteredBackground
        case enteredForeground
        /// The device reported a change to the album `albumID`'s pass conditions.
        case deviceStateChanged(albumID: String, DeviceStateChange)
        /// The wait after a full iCloud is over.
        case quotaRetryCameDue(albumID: String)
        /// The requested albums should carry on: a launch with credentials
        /// ready. Starts a round.
        case continueRequested
        /// The album step run for a requested album returned.
        case albumStepEnded(albumID: String, result: AlbumStepResult)
        /// These albums join the order, in this order, without starting.
        case albumsRequested(albumIDs: [String])
    }

    enum Effect: Equatable, Sendable {
        case startPass(albumID: String, folder: URL)
        /// Ask the running pass to stop before its next item.
        case requestStopOfRunningPass(albumID: String, because: StopReason)
        /// Let the running pass go on if it was asked to stop for this reason.
        case withdrawStopOfRunningPass(albumID: String, requestedBecause: StopReason)
        /// Cancel the running pass where it is.
        case cancelRunningPass
        /// Answer whoever awaits the outcome of a pass that will not run.
        case answerAwaitingCallers(albumID: String, outcome: MigrationRunOutcome)
        case scheduleQuotaRetry(albumID: String, after: TimeInterval)
        /// Run the album step for a requested album that has no state yet,
        /// which starts its pass.
        case runAlbumStep(albumID: String)
        /// The order changed: store it.
        case saveRequestedAlbumIDs([String])
        /// An erase: remove the stored order.
        case removeStoredRequestedAlbumIDs
        /// The state changed, for these albums.
        case postStateDidChange(albumIDs: [String])
    }

    struct Transition: Equatable, Sendable {
        var state: SchedulerState
        var effects: [Effect]
    }

    // MARK: - Transition

    /// The state after `event`, and what to do about it. Pure: the same state
    /// and event always give the same answer.
    nonisolated static func nextStateAndEffects(after event: Event, in state: SchedulerState) -> Transition {
        var next = state
        var effects: [Effect] = []
        switch event {
        case .passStartRequested(let albumID, let folder, let isUserRequest):
            if isUserRequest {
                if !next.order.contains(albumID) { next.order.append(albumID) }
                next.albumIDsTriedThisRound.remove(albumID)
                next.albumIDsSkippedForThisLaunch.remove(albumID)
                if next.albumIDStoppingAtUserRequest == albumID {
                    next.albumIDStoppingAtUserRequest = nil
                    if next.itemWriteHolds[albumID] == nil {
                        effects.append(.withdrawStopOfRunningPass(albumID: albumID, requestedBecause: .stopRequested))
                    }
                }
            }
            claimOrQueuePass(albumID: albumID, folder: folder, mayWait: next.order.contains(albumID),
                             in: &next, effects: &effects)

        case .passMadeProgress(let albumID):
            forgetPause(ofAlbumID: albumID, in: &next)

        case .passEnded(let albumID, let ending):
            recordPassEnd(albumID: albumID, ending: ending, in: &next, effects: &effects)
            startNextAlbum(in: &next, effects: &effects)

        case .stopRequested(let albumID):
            stopPass(ofAlbumID: albumID, answeringWith: .stopRequested, in: &next, effects: &effects)

        case .holdTaken(let albumID):
            next.itemWriteHolds[albumID, default: 0] += 1
            stopPass(ofAlbumID: albumID, answeringWith: .stopRequested, in: &next, effects: &effects)

        case .holdReleased(let albumID):
            guard let count = next.itemWriteHolds[albumID] else { break }
            next.itemWriteHolds[albumID] = count > 1 ? count - 1 : nil
            if count == 1 {
                next.albumIDsTriedThisRound.remove(albumID)
                startNextAlbum(in: &next, effects: &effects)
            }

        case .albumForgotten(let albumID):
            removeAlbumFromWaitingList(albumID, answeringWith: .albumNotOnDevice, in: &next, effects: &effects)
            next.order.removeAll { $0 == albumID }
            next.albumIDsTriedThisRound.remove(albumID)
            next.albumIDsSkippedForThisLaunch.remove(albumID)
            forgetPause(ofAlbumID: albumID, in: &next)
            releaseListHold(heldByAlbumID: albumID, in: &next, effects: &effects)
            if next.continuingAlbumID == albumID {
                next.continuingAlbumID = nil
                startNextAlbum(in: &next, effects: &effects)
            }

        case .userPaused(let albumID):
            next.order.removeAll { $0 == albumID }
            next.albumIDsTriedThisRound.remove(albumID)
            next.albumIDsSkippedForThisLaunch.remove(albumID)
            removeAlbumFromWaitingList(albumID, answeringWith: .stopRequested, in: &next, effects: &effects)
            if next.albums[albumID]?.isRunning == true {
                next.albumIDStoppingAtUserRequest = albumID
                effects.append(.requestStopOfRunningPass(albumID: albumID, because: .stopRequested))
            }
            forgetPause(ofAlbumID: albumID, in: &next)
            releaseListHold(heldByAlbumID: albumID, in: &next, effects: &effects)
            if next.continuingAlbumID == albumID {
                next.continuingAlbumID = nil
                startNextAlbum(in: &next, effects: &effects)
            }

        case .erased:
            emptyWaitingList(answeringWith: .erased, in: &next, effects: &effects)
            next.albums = next.albums.compactMapValues { album in
                guard case .running(let folder, _) = album else { return nil }
                return .running(folder: folder, keptPause: nil)
            }
            next.order = []
            next.continuingAlbumID = nil
            next.albumIDsTriedThisRound = []
            next.albumIDsSkippedForThisLaunch = []
            next.albumIDStoppingAtUserRequest = nil
            next.listHeldBy = nil
            if next.runningAlbumID != nil { effects.append(.cancelRunningPass) }

        case .enteredBackground:
            guard !next.isInBackground else { break }
            next.isInBackground = true
            if let albumID = next.runningAlbumID {
                effects.append(.requestStopOfRunningPass(albumID: albumID, because: .inBackground))
            }

        case .enteredForeground:
            guard next.isInBackground else { break }
            next.isInBackground = false
            if let albumID = next.runningAlbumID {
                effects.append(.withdrawStopOfRunningPass(albumID: albumID, requestedBecause: .inBackground))
            }
            next.albumIDsTriedThisRound = []
            startNextAlbum(in: &next, effects: &effects)

        case .deviceStateChanged(let albumID, let change):
            guard let pause = next.albums[albumID]?.pause else { break }
            switch pause.reason {
            case .lowPowerMode, .thermalState:
                guard change.change == .powerOrThermalState else { break }
                if let reason = change.devicePauseReason {
                    replacePauseReason(ofAlbumID: albumID, with: reason, in: &next)
                } else {
                    resumePausedAlbum(albumID, in: &next, effects: &effects)
                }
            case .accountUnavailable:
                guard change.change == .account else { break }
                resumePausedAlbum(albumID, in: &next, effects: &effects)
            case .waitingForWiFi:
                guard change.change == .network, change.isOnUnmeteredNetwork else { break }
                resumePausedAlbum(albumID, in: &next, effects: &effects)
            case .quota, .schemaNotDeployed:
                break
            }

        case .quotaRetryCameDue(let albumID):
            guard next.albums[albumID]?.pause?.reason == .quota else { break }
            resumePausedAlbum(albumID, in: &next, effects: &effects)

        case .continueRequested:
            next.albumIDsTriedThisRound = []
            startNextAlbum(in: &next, effects: &effects)

        case .albumStepEnded(let albumID, let result):
            guard next.continuingAlbumID == albumID else { break }
            next.continuingAlbumID = nil
            switch result {
            case .startedPass, .cannotContinueThisRound:
                break
            case .waitsForConditions:
                next.albumIDsTriedThisRound.formUnion(next.order.filter { next.albums[$0] == nil })
            case .cannotContinueThisLaunch:
                next.albumIDsSkippedForThisLaunch.insert(albumID)
            case .nothingToContinue:
                next.order.removeAll { $0 == albumID }
                next.albumIDsTriedThisRound.remove(albumID)
            }
            startNextAlbum(in: &next, effects: &effects)

        case .albumsRequested(let albumIDs):
            for albumID in albumIDs where !next.order.contains(albumID) {
                next.order.append(albumID)
            }
        }

        if event == .erased {
            effects.append(.removeStoredRequestedAlbumIDs)
        } else if next.order != state.order {
            effects.append(.saveRequestedAlbumIDs(next.order))
        }
        if next != state {
            effects.append(.postStateDidChange(albumIDs: albumIDsWhoseStateDiffers(between: state, and: next)))
        }
        return Transition(state: next, effects: effects)
    }

    /// Gives the album the turn, or makes it wait while another album runs if
    /// it `mayWait`: a requested album, or a paused one resuming. An album
    /// already waiting stays where it is, also while the list is held. Nothing
    /// changes for an album that is running or held by an item write, or while
    /// the app is in the background.
    nonisolated private static func claimOrQueuePass(albumID: String, folder: URL, mayWait: Bool,
                                                     in state: inout SchedulerState, effects: inout [Effect]) {
        let album = state.albums[albumID]
        if album?.isRunning == true { return }
        guard state.itemWriteHolds[albumID] == nil, !state.isInBackground else { return }
        if album?.isWaiting == true { return }
        let isTurnFree = state.runningAlbumID == nil
            && (state.continuingAlbumID == nil || state.continuingAlbumID == albumID)
        guard isTurnFree else {
            if mayWait { state.albums[albumID] = .waiting(folder: folder, keptPause: album?.pause) }
            return
        }
        giveTurn(toAlbumID: albumID, folder: folder, keptPause: album?.pause, in: &state, effects: &effects)
    }

    /// Makes the album's pass the one running, which ends any hold on the list.
    nonisolated private static func giveTurn(toAlbumID albumID: String, folder: URL, keptPause: AlbumPause?,
                                             in state: inout SchedulerState, effects: inout [Effect]) {
        state.albums[albumID] = .running(folder: folder, keptPause: keptPause)
        state.listHeldBy = nil
        if state.continuingAlbumID == albumID { state.continuingAlbumID = nil }
        effects.append(.startPass(albumID: albumID, folder: folder))
    }

    /// The waiting albums in the order they start in: the requested ones as
    /// they were asked for, then any other, by id.
    nonisolated static func waitingAlbumIDsInStartOrder(in state: SchedulerState) -> [String] {
        let requested = state.order.filter { state.albums[$0]?.isWaiting == true }
        let others = state.albums.filter { $0.value.isWaiting && !state.order.contains($0.key) }.keys.sorted()
        return requested + others
    }

    /// Gives the turn to the next album, once nothing runs and no album step
    /// is in flight. The requested albums come first, in the order they were
    /// asked for: one that waits starts its pass, one that has no state gets
    /// its album step, which starts its pass, unless it was tried in this round
    /// already or cannot continue in this launch. A paused album and one held
    /// by an item write are passed over.
    /// Then any other waiting album starts. Nothing starts in the background or
    /// while the list is held.
    nonisolated private static func startNextAlbum(in state: inout SchedulerState, effects: inout [Effect]) {
        guard state.runningAlbumID == nil, state.continuingAlbumID == nil, !state.isInBackground,
              state.listHeldBy == nil else { return }
        for albumID in state.order where state.itemWriteHolds[albumID] == nil {
            switch state.albums[albumID] {
            case .waiting(let folder, let keptPause):
                return giveTurn(toAlbumID: albumID, folder: folder, keptPause: keptPause, in: &state, effects: &effects)
            case .running, .paused:
                continue
            case nil:
                guard !state.albumIDsTriedThisRound.contains(albumID),
                      !state.albumIDsSkippedForThisLaunch.contains(albumID) else { continue }
                state.albumIDsTriedThisRound.insert(albumID)
                state.continuingAlbumID = albumID
                effects.append(.runAlbumStep(albumID: albumID))
                return
            }
        }
        guard let albumID = waitingAlbumIDsInStartOrder(in: state).first, let album = state.albums[albumID] else { return }
        giveTurn(toAlbumID: albumID, folder: album.folder, keptPause: album.pause, in: &state, effects: &effects)
    }

    /// Records how the album's pass ended. A pass stopped for a pause reason, or
    /// offline, leaves the album paused, and holds the list when the reason
    /// stops every album; one stopped for anything else forgets a device-state
    /// or Wi-Fi pause it resumed from. A pass that found no plan, or no album
    /// on this device, takes the album out of the order: nothing is left to
    /// continue. So does one that tried every item and left only deferred ones:
    /// the album stays readable from its folder and the next album goes on. The
    /// pass of an album the user paused leaves no pause, whatever it stopped for.
    nonisolated private static func recordPassEnd(albumID: String, ending: PassEnding,
                                                  in state: inout SchedulerState, effects: inout [Effect]) {
        guard case .running(let folder, let keptPause) = state.albums[albumID] else { return }
        if state.albumIDStoppingAtUserRequest == albumID {
            state.albumIDStoppingAtUserRequest = nil
            state.albums[albumID] = nil
            return
        }
        var pause = keptPause
        if case .stopped(let stopReason, _) = ending.outcome {
            if let reason = pauseReason(forStop: stopReason) {
                pause = AlbumPause(reason: reason, bytesStillNeeded: ending.bytesStillNeeded)
                if reason.isDeviceWide { state.listHeldBy = albumID }
                if reason == .quota, let retryAfter = ending.retryAfter {
                    effects.append(.scheduleQuotaRetry(albumID: albumID, after: retryAfter))
                }
            } else if let kept = keptPause, kept.reason.isDeviceState || kept.reason == .waitingForWiFi {
                pause = nil
            }
            if stopReason == .noPlan || stopReason == .albumNotOnDevice {
                state.order.removeAll { $0 == albumID }
            }
        } else if case .finished = ending.outcome, ending.leavesOnlyDeferredItems {
            state.order.removeAll { $0 == albumID }
        }
        state.albums[albumID] = pause.map { .paused(folder: folder, reason: $0.reason, bytesStillNeeded: $0.bytesStillNeeded) }
        if pause == nil, state.order.contains(albumID) { state.albumIDsTriedThisRound.insert(albumID) }
    }

    /// The pause a pass that stopped for `stopReason` leaves its album with.
    nonisolated static func pauseReason(forStop stopReason: StopReason) -> PauseReason? {
        switch stopReason {
        case .paused(let reason): return reason
        case .offline: return .waitingForWiFi
        default: return nil
        }
    }

    /// Takes the album off the list, and asks its pass to stop if it runs.
    nonisolated private static func stopPass(ofAlbumID albumID: String, answeringWith stopReason: StopReason,
                                             in state: inout SchedulerState, effects: inout [Effect]) {
        removeAlbumFromWaitingList(albumID, answeringWith: stopReason, in: &state, effects: &effects)
        if state.albums[albumID]?.isRunning == true {
            effects.append(.requestStopOfRunningPass(albumID: albumID, because: stopReason))
        }
    }

    /// Stops a waiting album from waiting without starting it. It keeps the
    /// pause it resumed from and its place in the order.
    nonisolated private static func removeAlbumFromWaitingList(_ albumID: String, answeringWith stopReason: StopReason,
                                                               in state: inout SchedulerState, effects: inout [Effect]) {
        guard case .waiting(let folder, let keptPause) = state.albums[albumID] else { return }
        state.albums[albumID] = keptPause.map { .paused(folder: folder, reason: $0.reason, bytesStillNeeded: $0.bytesStillNeeded) }
        effects.append(.answerAwaitingCallers(albumID: albumID, outcome: .stopped(stopReason, MigrationPassReport())))
    }

    nonisolated private static func emptyWaitingList(answeringWith stopReason: StopReason,
                                                     in state: inout SchedulerState, effects: inout [Effect]) {
        for albumID in waitingAlbumIDsInStartOrder(in: state) {
            removeAlbumFromWaitingList(albumID, answeringWith: stopReason, in: &state, effects: &effects)
        }
    }

    /// Lets the list go on if the album holds it.
    nonisolated private static func releaseListHold(heldByAlbumID albumID: String,
                                                    in state: inout SchedulerState, effects: inout [Effect]) {
        guard state.listHeldBy == albumID else { return }
        state.listHeldBy = nil
        startNextAlbum(in: &state, effects: &effects)
    }

    nonisolated private static func forgetPause(ofAlbumID albumID: String, in state: inout SchedulerState) {
        switch state.albums[albumID] {
        case .waiting(let folder, _): state.albums[albumID] = .waiting(folder: folder, keptPause: nil)
        case .running(let folder, _): state.albums[albumID] = .running(folder: folder, keptPause: nil)
        case .paused: state.albums[albumID] = nil
        case nil: break
        }
    }

    nonisolated private static func replacePauseReason(ofAlbumID albumID: String, with reason: PauseReason,
                                                       in state: inout SchedulerState) {
        switch state.albums[albumID] {
        case .waiting(let folder, let keptPause?):
            state.albums[albumID] = .waiting(folder: folder, keptPause: AlbumPause(reason: reason, bytesStillNeeded: keptPause.bytesStillNeeded))
        case .running(let folder, let keptPause?):
            state.albums[albumID] = .running(folder: folder, keptPause: AlbumPause(reason: reason, bytesStillNeeded: keptPause.bytesStillNeeded))
        case .paused(let folder, _, let bytesStillNeeded):
            state.albums[albumID] = .paused(folder: folder, reason: reason, bytesStillNeeded: bytesStillNeeded)
        default:
            break
        }
    }

    /// Starts a paused album again, or makes it wait while another album runs.
    /// A device-state pause is forgotten first; any other stays with the album.
    /// A resume that may not start ends the album's hold on the list. In the
    /// background nothing starts, and a Wi-Fi pause is forgotten too.
    nonisolated private static func resumePausedAlbum(_ albumID: String,
                                                      in state: inout SchedulerState, effects: inout [Effect]) {
        guard let album = state.albums[albumID], let pause = album.pause else { return }
        if pause.reason.isDeviceState || (state.isInBackground && pause.reason == .waitingForWiFi && !album.isRunning) {
            forgetPause(ofAlbumID: albumID, in: &state)
        }
        if album.isRunning { return }
        claimOrQueuePass(albumID: albumID, folder: album.folder, mayWait: true, in: &state, effects: &effects)
        let resumed = state.albums[albumID]
        if resumed?.isRunning != true, resumed?.isWaiting != true {
            releaseListHold(heldByAlbumID: albumID, in: &state, effects: &effects)
        }
    }

    /// The albums whose state, place in line or hold on the list differs
    /// between the two states, sorted.
    nonisolated private static func albumIDsWhoseStateDiffers(between old: SchedulerState, and new: SchedulerState) -> [String] {
        var changed = Set<String>()
        for albumID in Set(old.albums.keys).union(new.albums.keys) where old.albums[albumID] != new.albums[albumID] {
            changed.insert(albumID)
        }
        changed.formUnion(Set(old.order).symmetricDifference(new.order))
        if old.listHeldBy != new.listHeldBy {
            if let holder = old.listHeldBy { changed.insert(holder) }
            if let holder = new.listHeldBy { changed.insert(holder) }
        }
        return changed.sorted()
    }
}
