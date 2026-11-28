//
//  ICloudDriveUpgradeSchedulerTests.swift
//  EncameraCoreTests
//
//  The blob migration's scheduler. The transition tests check
//  `ICloudDriveUpgradeScheduler.nextStateAndEffects(after:in:)` on values alone:
//  which album runs, which wait and in what order, what holds the list and what
//  lets it go on.
//

import XCTest
@testable import EncameraCore

final class ICloudDriveUpgradeSchedulerTests: XCTestCase {

    typealias Scheduler = ICloudDriveUpgradeScheduler
    typealias SchedulerState = Scheduler.SchedulerState
    typealias Event = Scheduler.Event
    typealias Effect = Scheduler.Effect
    typealias PauseReason = Scheduler.PauseReason
    typealias StopReason = Scheduler.StopReason
    typealias MigrationRunOutcome = Scheduler.MigrationRunOutcome
    typealias MigrationPassReport = Scheduler.MigrationPassReport

    private func folder(_ albumID: String) -> URL {
        URL(fileURLWithPath: "/folders/\(albumID)", isDirectory: true)
    }

    /// The user's request for the album's upgrade.
    private func requested(_ albumID: String) -> Event {
        .passStartRequested(albumID: albumID, folder: folder(albumID), isUserRequest: true)
    }

    /// A one-off start: a viewer open, or the end of an item edit or move.
    private func oneOff(_ albumID: String) -> Event {
        .passStartRequested(albumID: albumID, folder: folder(albumID), isUserRequest: false)
    }

    /// The albums waiting their turn, in the order they start in.
    private func waiting(_ state: SchedulerState) -> [String] {
        Scheduler.waitingAlbumIDsInStartOrder(in: state)
    }

    private func ended(_ albumID: String, _ outcome: MigrationRunOutcome,
                       bytesStillNeeded: Int64? = nil, retryAfter: TimeInterval? = nil) -> Event {
        .passEnded(albumID: albumID,
                   ending: Scheduler.PassEnding(outcome: outcome, bytesStillNeeded: bytesStillNeeded, retryAfter: retryAfter))
    }

    private func stopped(_ albumID: String, _ reason: StopReason) -> Event {
        ended(albumID, .stopped(reason, MigrationPassReport()))
    }

    private func finished(_ albumID: String) -> Event {
        ended(albumID, .finished(MigrationPassReport()))
    }

    private func transition(_ event: Event, in state: SchedulerState) -> Scheduler.Transition {
        Scheduler.nextStateAndEffects(after: event, in: state)
    }

    /// The state after every event in `events`, in order, starting from `state`.
    private func state(after events: [Event], from state: SchedulerState = SchedulerState()) -> SchedulerState {
        events.reduce(state) { transition($1, in: $0).state }
    }

    private func startedAlbumIDs(_ effects: [Effect]) -> [String] {
        effects.compactMap { effect in
            if case .startPass(let albumID, _) = effect { return albumID }
            return nil
        }
    }

    private static let deviceWideReasons: [PauseReason] = [
        .lowPowerMode, .thermalState(.serious), .waitingForWiFi, .accountUnavailable, .quota
    ]

    // MARK: - Starting and waiting

    func testFirstRequestStartsItsPass() {
        let result = transition(requested("a"), in: SchedulerState())

        XCTAssertEqual(result.state.albums, ["a": .running(folder: folder("a"), keptPause: nil)])
        XCTAssertEqual(waiting(result.state), [])
        XCTAssertEqual(result.state.runningAlbumID, "a")
        XCTAssertEqual(result.effects, [.startPass(albumID: "a", folder: folder("a")),
                                        .saveRequestedAlbumIDs(["a"]),
                                        .postStateDidChange(albumIDs: ["a"])])
    }

    func testSecondRequestWaitsBehindTheRunningAlbum() {
        let running = state(after: [requested("a")])

        let result = transition(requested("b"), in: running)

        XCTAssertEqual(result.state.albums["a"], .running(folder: folder("a"), keptPause: nil))
        XCTAssertEqual(result.state.albums["b"], .waiting(folder: folder("b"), keptPause: nil))
        XCTAssertEqual(waiting(result.state), ["b"])
        XCTAssertEqual(startedAlbumIDs(result.effects), [], "nothing starts while another album runs")
        XCTAssertEqual(result.effects, [.saveRequestedAlbumIDs(["a", "b"]), .postStateDidChange(albumIDs: ["b"])])
    }

    func testDuplicateRequestChangesNothing() {
        let before = state(after: [requested("a"), requested("b"), requested("c")])

        for albumID in ["a", "b", "c"] {
            let result = transition(requested(albumID), in: before)

            XCTAssertEqual(result.state, before, "\(albumID) keeps its state and its place in line")
            XCTAssertEqual(result.effects, [], "\(albumID) starts nothing and posts nothing")
        }
    }

    func testPassEndStartsTheAlbumThatWaitedLongest() {
        var current = state(after: [requested("a"), requested("c"), requested("b")])
        XCTAssertEqual(waiting(current), ["c", "b"])

        var result = transition(finished("a"), in: current)
        XCTAssertEqual(startedAlbumIDs(result.effects), ["c"], "c asked before b")
        XCTAssertEqual(result.state.runningAlbumID, "c")
        XCTAssertEqual(waiting(result.state), ["b"])
        XCTAssertNil(result.state.albums["a"], "a finished album is not kept")
        current = result.state

        result = transition(finished("c"), in: current)
        XCTAssertEqual(startedAlbumIDs(result.effects), ["b"])
        XCTAssertEqual(waiting(result.state), [])
        current = result.state

        result = transition(finished("b"), in: current)
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
        XCTAssertEqual(result.state.albums, [:])
    }

    func testAtMostOneAlbumRunsAfterAnySequenceOfStartsAndEnds() {
        var current = SchedulerState()
        let events: [Event] = [requested("a"), requested("b"), requested("c"), finished("a"), requested("a"),
                               stopped("b", .stopRequested), finished("a"), finished("c")]
        for event in events {
            current = transition(event, in: current).state
            XCTAssertLessThanOrEqual(current.albums.values.filter(\.isRunning).count, 1, "after \(event)")
        }
        XCTAssertEqual(current.albums, [:])
    }

    // MARK: - Pauses and the hold on the list

    func testDeviceWidePauseHoldsTheWaitingList() {
        for reason in Self.deviceWideReasons {
            let before = state(after: [requested("a"), requested("b")])

            let result = transition(stopped("a", .paused(reason)), in: before)

            XCTAssertEqual(result.state.listHeldBy, "a", "\(reason)")
            XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: reason, bytesStillNeeded: nil), "\(reason)")
            XCTAssertEqual(result.state.albums["b"], .waiting(folder: folder("b"), keptPause: nil), "\(reason)")
            XCTAssertEqual(waiting(result.state), ["b"], "\(reason)")
            XCTAssertEqual(startedAlbumIDs(result.effects), [], "\(reason): the next album would only stop for the same reason")
        }
    }

    func testPassStoppedOfflineHoldsTheListWaitingForWiFi() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(stopped("a", .offline), in: before)

        XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: .waitingForWiFi, bytesStillNeeded: nil))
        XCTAssertEqual(result.state.listHeldBy, "a")
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
    }

    func testAlbumSpecificStopHandsTheTurnOn() {
        let albumSpecificStops: [StopReason] = [.paused(.schemaNotDeployed), .stopRequested, .noPlan, .albumNotOnDevice,
                                                .locked, .folderNotInContainer, .iCloudDriveUnavailable]
        for stopReason in albumSpecificStops {
            let before = state(after: [requested("a"), requested("b")])

            let result = transition(stopped("a", stopReason), in: before)

            XCTAssertNil(result.state.listHeldBy, "\(stopReason)")
            XCTAssertEqual(startedAlbumIDs(result.effects), ["b"], "\(stopReason)")
            XCTAssertEqual(result.state.albums["b"], .running(folder: folder("b"), keptPause: nil), "\(stopReason)")
        }

        let before = state(after: [requested("a"), requested("b")])
        let result = transition(finished("a"), in: before)
        XCTAssertEqual(startedAlbumIDs(result.effects), ["b"], "a pass that tried every item hands the turn on")
    }

    func testSchemaPauseIsRecordedForTheAlbumThatStopped() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(stopped("a", .paused(.schemaNotDeployed)), in: before)

        XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: .schemaNotDeployed, bytesStillNeeded: nil))
    }

    func testAStartForAnAlbumNotOnAHeldListRunsAtOnceAndEndsTheHold() {
        let held = state(after: [requested("a"), requested("b"), stopped("a", .paused(.lowPowerMode))])
        XCTAssertEqual(held.listHeldBy, "a")

        let result = transition(requested("c"), in: held)

        XCTAssertEqual(startedAlbumIDs(result.effects), ["c"])
        XCTAssertNil(result.state.listHeldBy, "a pass that starts ends the hold")
        XCTAssertEqual(waiting(result.state), ["b"], "the waiting album keeps its place")

        let afterEnd = transition(finished("c"), in: result.state)
        XCTAssertEqual(startedAlbumIDs(afterEnd.effects), ["b"], "the list goes on when that pass ends")
    }

    func testAWaitingAlbumStaysOnAHeldListWhenAskedAgain() {
        let held = state(after: [requested("a"), requested("b"), stopped("a", .paused(.lowPowerMode))])

        let result = transition(requested("b"), in: held)

        XCTAssertEqual(result.state, held)
        XCTAssertEqual(result.effects, [])
    }

    func testForgettingTheHolderReleasesTheList() {
        let held = state(after: [requested("a"), requested("b"), requested("c"), stopped("a", .paused(.accountUnavailable))])
        XCTAssertEqual(held.listHeldBy, "a")

        let result = transition(.albumForgotten(albumID: "a"), in: held)

        XCTAssertNil(result.state.listHeldBy)
        XCTAssertNil(result.state.albums["a"], "the holder's pause is forgotten")
        XCTAssertEqual(startedAlbumIDs(result.effects), ["b"], "the album that waited longest starts")
        XCTAssertEqual(waiting(result.state), ["c"])
    }

    func testForgettingAnAlbumThatDoesNotHoldTheListLeavesItHeld() {
        let held = state(after: [requested("a"), requested("b"), requested("c"), stopped("a", .paused(.lowPowerMode))])

        let result = transition(.albumForgotten(albumID: "c"), in: held)

        XCTAssertEqual(result.state.listHeldBy, "a")
        XCTAssertEqual(waiting(result.state), ["b"])
        XCTAssertNil(result.state.albums["c"])
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
        XCTAssertTrue(result.effects.contains(.answerAwaitingCallers(albumID: "c", outcome: .stopped(.albumNotOnDevice, MigrationPassReport()))))
    }

    // MARK: - A full iCloud

    private func stoppedForQuota(_ albumID: String) -> Event {
        ended(albumID, .stopped(.paused(.quota), MigrationPassReport()), bytesStillNeeded: 1_000, retryAfter: 60)
    }

    func testQuotaPauseHoldsTheWaitingList() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(stoppedForQuota("a"), in: before)

        XCTAssertEqual(result.state.listHeldBy, "a")
        XCTAssertEqual(startedAlbumIDs(result.effects), [], "the next album would fill the same storage")
        XCTAssertEqual(result.state.albums["b"], .waiting(folder: folder("b"), keptPause: nil))
        XCTAssertEqual(waiting(result.state), ["b"])
        XCTAssertTrue(result.effects.contains(.scheduleQuotaRetry(albumID: "a", after: 60)))
    }

    func testQuotaRetryReleasesTheListAndResumesThePausedAlbum() {
        let held = state(after: [requested("a"), requested("b"), stoppedForQuota("a")])

        let retried = transition(.quotaRetryCameDue(albumID: "a"), in: held)

        XCTAssertEqual(startedAlbumIDs(retried.effects), ["a"], "the paused album goes first")
        XCTAssertNil(retried.state.listHeldBy)
        XCTAssertEqual(waiting(retried.state), ["b"])

        let progressed = transition(.passMadeProgress(albumID: "a"), in: retried.state)
        let ended = transition(finished("a"), in: progressed.state)
        XCTAssertEqual(startedAlbumIDs(ended.effects), ["b"], "the second album follows it")
        XCTAssertNil(ended.state.albums["a"])
    }

    func testQuotaRetryThatFindsICloudStillFullHoldsTheListAgain() {
        let retried = state(after: [requested("a"), requested("b"), stoppedForQuota("a"), .quotaRetryCameDue(albumID: "a")])

        let result = transition(stoppedForQuota("a"), in: retried)

        XCTAssertEqual(result.state.listHeldBy, "a")
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
        XCTAssertEqual(waiting(result.state), ["b"])
    }

    func testSchemaPauseStillHandsTheTurnOn() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(stopped("a", .paused(.schemaNotDeployed)), in: before)

        XCTAssertNil(result.state.listHeldBy)
        XCTAssertEqual(startedAlbumIDs(result.effects), ["b"])
        XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: .schemaNotDeployed, bytesStillNeeded: nil))
    }

    // MARK: - Resuming a paused album

    private func deviceChanged(_ albumID: String, _ change: Scheduler.DeviceResourceStateObserver.Change,
                               devicePauseReason: PauseReason? = nil, isOnUnmeteredNetwork: Bool = true) -> Event {
        .deviceStateChanged(albumID: albumID,
                            Scheduler.DeviceStateChange(change: change, devicePauseReason: devicePauseReason,
                                                        isOnUnmeteredNetwork: isOnUnmeteredNetwork))
    }

    func testLowPowerModeClearingResumesThePausedAlbum() {
        let paused = state(after: [requested("a"), requested("b"), stopped("a", .paused(.lowPowerMode))])
        XCTAssertEqual(paused.listHeldBy, "a")

        let stillOn = transition(deviceChanged("a", .powerOrThermalState, devicePauseReason: .lowPowerMode), in: paused)
        XCTAssertEqual(stillOn.state, paused, "nothing resumes while Low Power Mode is on")
        XCTAssertEqual(stillOn.effects, [])

        let result = transition(deviceChanged("a", .powerOrThermalState), in: paused)

        XCTAssertEqual(startedAlbumIDs(result.effects), ["a"])
        XCTAssertEqual(result.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "a device-state pause is forgotten on resume")
        XCTAssertNil(result.state.listHeldBy, "the resume ends the hold")
        XCTAssertEqual(waiting(result.state), ["b"], "the waiting album goes on when the resumed pass ends")
    }

    func testThermalReasonChangeUpdatesThePauseWithoutResuming() {
        let paused = state(after: [requested("a"), stopped("a", .paused(.thermalState(.serious)))])

        let hotter = transition(deviceChanged("a", .powerOrThermalState, devicePauseReason: .thermalState(.critical)), in: paused)
        XCTAssertEqual(hotter.state.albums["a"], .paused(folder: folder("a"), reason: .thermalState(.critical), bytesStillNeeded: nil))
        XCTAssertEqual(startedAlbumIDs(hotter.effects), [])
        XCTAssertEqual(hotter.effects, [.postStateDidChange(albumIDs: ["a"])], "the new reason is posted")

        let lowPower = transition(deviceChanged("a", .powerOrThermalState, devicePauseReason: .lowPowerMode), in: hotter.state)
        XCTAssertEqual(lowPower.state.albums["a"], .paused(folder: folder("a"), reason: .lowPowerMode, bytesStillNeeded: nil))
        XCTAssertEqual(startedAlbumIDs(lowPower.effects), [])

        let cooled = transition(deviceChanged("a", .powerOrThermalState), in: lowPower.state)
        XCTAssertEqual(startedAlbumIDs(cooled.effects), ["a"], "it resumes once no reason is left")
    }

    func testWiFiReturnResumesThePausedAlbum() {
        let paused = state(after: [requested("a"), stopped("a", .paused(.waitingForWiFi))])

        for unrelated in [deviceChanged("a", .network, isOnUnmeteredNetwork: false), deviceChanged("a", .powerOrThermalState),
                          deviceChanged("a", .account), deviceChanged("other", .network)] {
            let result = transition(unrelated, in: paused)
            XCTAssertEqual(result.state, paused, "\(unrelated)")
            XCTAssertEqual(result.effects, [], "\(unrelated)")
        }

        let result = transition(deviceChanged("a", .network), in: paused)

        XCTAssertEqual(startedAlbumIDs(result.effects), ["a"])
        XCTAssertEqual(result.state.albums["a"],
                       .running(folder: folder("a"), keptPause: Scheduler.AlbumPause(reason: .waitingForWiFi, bytesStillNeeded: nil)),
                       "the pause stays with the album until its pass makes progress")
    }

    func testAccountChangeResumesThePausedAlbum() {
        let paused = state(after: [requested("a"), stopped("a", .paused(.accountUnavailable))])

        for unrelated in [deviceChanged("a", .network), deviceChanged("a", .powerOrThermalState)] {
            XCTAssertEqual(transition(unrelated, in: paused).state, paused, "\(unrelated)")
        }

        let result = transition(deviceChanged("a", .account), in: paused)

        XCTAssertEqual(startedAlbumIDs(result.effects), ["a"])
        XCTAssertEqual(result.state.albums["a"]?.pause?.reason, .accountUnavailable)
        XCTAssertNil(result.state.listHeldBy)
    }

    func testQuotaPauseSchedulesARetry() {
        let running = state(after: [requested("a")])

        let result = transition(ended("a", .stopped(.paused(.quota), MigrationPassReport()), bytesStillNeeded: 42, retryAfter: 60),
                                in: running)

        XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: .quota, bytesStillNeeded: 42))
        XCTAssertTrue(result.effects.contains(.scheduleQuotaRetry(albumID: "a", after: 60)))

        for change in [Scheduler.DeviceResourceStateObserver.Change.powerOrThermalState, .account, .network] {
            XCTAssertEqual(transition(deviceChanged("a", change), in: result.state).state, result.state,
                           "\(change) does not resume a full iCloud")
        }

        let retried = transition(.quotaRetryCameDue(albumID: "a"), in: result.state)
        XCTAssertEqual(startedAlbumIDs(retried.effects), ["a"])
        XCTAssertEqual(retried.state.albums["a"],
                       .running(folder: folder("a"), keptPause: Scheduler.AlbumPause(reason: .quota, bytesStillNeeded: 42)))

        let withoutInterval = transition(stopped("a", .paused(.quota)), in: running)
        XCTAssertFalse(withoutInterval.effects.contains { if case .scheduleQuotaRetry = $0 { return true } else { return false } },
                       "no retry is scheduled without an interval")
    }

    func testQuotaRetryOfAnAlbumNoLongerPausedForQuotaDoesNothing() {
        let before = state(after: [requested("a"), stopped("a", .paused(.accountUnavailable))])

        let result = transition(.quotaRetryCameDue(albumID: "a"), in: before)

        XCTAssertEqual(result.state, before)
        XCTAssertEqual(result.effects, [])
    }

    func testSchemaPauseIsNotRetried() {
        let paused = state(after: [requested("a"), stopped("a", .paused(.schemaNotDeployed))])

        let events = [deviceChanged("a", .powerOrThermalState), deviceChanged("a", .account), deviceChanged("a", .network),
                      Event.quotaRetryCameDue(albumID: "a")]
        for event in events {
            let result = transition(event, in: paused)
            XCTAssertEqual(result.state, paused, "\(event)")
            XCTAssertEqual(result.effects, [], "\(event)")
        }
    }

    func testRefusedResumeReleasesTheHeldList() {
        let held = state(after: [requested("a"), requested("b"), stopped("a", .paused(.lowPowerMode)),
                                 .holdTaken(albumID: "a")])
        XCTAssertEqual(held.listHeldBy, "a")

        let result = transition(deviceChanged("a", .powerOrThermalState), in: held)

        XCTAssertNil(result.state.listHeldBy, "the resume that would have ended the hold may not start")
        XCTAssertEqual(startedAlbumIDs(result.effects), ["b"], "the list goes on")
        XCTAssertNil(result.state.albums["a"], "the album held by an item write does not start")
    }

    func testResumedAlbumWaitsWhileAnotherAlbumRuns() {
        let before = state(after: [requested("a"), stopped("a", .paused(.accountUnavailable)), requested("b")])

        let result = transition(deviceChanged("a", .account), in: before)

        XCTAssertEqual(startedAlbumIDs(result.effects), [])
        XCTAssertEqual(result.state.albums["a"],
                       .waiting(folder: folder("a"), keptPause: Scheduler.AlbumPause(reason: .accountUnavailable, bytesStillNeeded: nil)))
        XCTAssertEqual(waiting(result.state), ["a"])
    }

    func testKeptPauseIsForgottenWhenThePassMakesProgress() {
        let resumed = state(after: [requested("a"), stopped("a", .paused(.quota)), .quotaRetryCameDue(albumID: "a")])
        XCTAssertEqual(resumed.albums["a"]?.pause?.reason, .quota)

        let result = transition(.passMadeProgress(albumID: "a"), in: resumed)

        XCTAssertEqual(result.state.albums["a"], .running(folder: folder("a"), keptPause: nil))
        XCTAssertEqual(result.effects, [.postStateDidChange(albumIDs: ["a"])])
    }

    func testKeptPauseOutlivesAPassThatFinishesWithoutProgress() {
        let resumed = state(after: [requested("a"), stopped("a", .paused(.quota)), .quotaRetryCameDue(albumID: "a")])

        let result = transition(finished("a"), in: resumed)

        XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: .quota, bytesStillNeeded: nil))
    }

    func testStopForAnotherReasonForgetsADeviceStateOrWiFiPauseOnly() {
        let afterWiFi = state(after: [requested("a"), stopped("a", .paused(.waitingForWiFi)), deviceChanged("a", .network),
                                      stopped("a", .stopRequested)])
        XCTAssertNil(afterWiFi.albums["a"], "a Wi-Fi pause is forgotten when the resumed pass stops for another reason")

        let afterAccount = state(after: [requested("a"), stopped("a", .paused(.accountUnavailable)), deviceChanged("a", .account),
                                         stopped("a", .stopRequested)])
        XCTAssertEqual(afterAccount.albums["a"]?.pause?.reason, .accountUnavailable, "an account pause stays")
    }

    // MARK: - Background

    func testBackgroundEventStopsTheRunningPass() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(.enteredBackground, in: before)

        XCTAssertTrue(result.state.isInBackground)
        XCTAssertTrue(result.effects.contains(.requestStopOfRunningPass(albumID: "a", because: .inBackground)),
                      "the running pass is asked to stop before its next item")
        XCTAssertEqual(result.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "it runs until its item is done")
        XCTAssertEqual(waiting(result.state), ["b"], "the waiting album keeps waiting")
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
    }

    func testBackgroundEventIsRecordedWhenNoPassRuns() {
        let result = transition(.enteredBackground, in: SchedulerState())

        XCTAssertTrue(result.state.isInBackground)
        XCTAssertEqual(result.effects, [.postStateDidChange(albumIDs: [])])

        let again = transition(.enteredBackground, in: result.state)
        XCTAssertEqual(again.state, result.state)
        XCTAssertEqual(again.effects, [])
    }

    func testNothingStartsFromTheListWhileInBackground() {
        let inBackground = state(after: [requested("a"), requested("b"), .enteredBackground])

        let ended = transition(stopped("a", .inBackground), in: inBackground)
        XCTAssertEqual(startedAlbumIDs(ended.effects), [], "a turn that comes up in the background starts nothing")
        XCTAssertEqual(ended.state.albums, ["b": .waiting(folder: folder("b"), keptPause: nil)])

        let oneOffAsked = transition(oneOff("c"), in: SchedulerState(isInBackground: true))
        XCTAssertEqual(oneOffAsked.state, SchedulerState(isInBackground: true), "a start in the background neither runs nor waits")
        XCTAssertEqual(oneOffAsked.effects, [])

        let requestAsked = transition(requested("c"), in: SchedulerState(isInBackground: true))
        XCTAssertEqual(startedAlbumIDs(requestAsked.effects), [])
        XCTAssertEqual(requestAsked.state.albums, [:])
        XCTAssertEqual(requestAsked.state.order, ["c"], "the request itself is kept")
    }

    func testReturningToTheForegroundCarriesOnWithTheAlbumsInTheOrderTheyWereAskedFor() {
        let inBackground = state(after: [requested("a"), requested("b"), .enteredBackground, stopped("a", .inBackground)])
        XCTAssertEqual(waiting(inBackground), ["b"])

        let result = transition(.enteredForeground, in: inBackground)
        XCTAssertFalse(result.state.isInBackground)
        XCTAssertEqual(albumStepsRun(result.effects), ["a"], "the album that was stopped was asked for first")
        XCTAssertEqual(startedAlbumIDs(result.effects), [])

        let stepOver = transition(stepEnded("a", .waitsForConditions), in: result.state)
        XCTAssertEqual(startedAlbumIDs(stepOver.effects), ["b"], "the album that waited through the background starts")

        let onlyWaiting = state(after: [oneOff("x"), requested("b"), .enteredBackground, stopped("x", .inBackground)])
        XCTAssertEqual(startedAlbumIDs(transition(.enteredForeground, in: onlyWaiting).effects), ["b"])
    }

    func testHeldListDoesNotResumeInBackground() {
        var held = state(after: [requested("a"), requested("b"), stopped("a", .paused(.lowPowerMode))])
        held.isInBackground = true
        XCTAssertEqual(held.listHeldBy, "a")
        XCTAssertEqual(waiting(held), ["b"])

        let result = transition(deviceChanged("a", .powerOrThermalState), in: held)

        XCTAssertEqual(startedAlbumIDs(result.effects), [], "neither the holder nor the waiting album starts in the background")
        XCTAssertNil(result.state.listHeldBy, "the hold ends with the reason")
        XCTAssertNil(result.state.albums["a"], "the device-state pause is forgotten")
        XCTAssertEqual(waiting(result.state), ["b"], "the waiting album keeps waiting")
        XCTAssertEqual(result.state.order, ["a", "b"])
    }

    func testResumeInBackgroundKeepsAPauseThatIsNotForTheDeviceStateOrWiFi() {
        for (reason, resume) in [(PauseReason.accountUnavailable, deviceChanged("a", .account)),
                                 (.quota, Event.quotaRetryCameDue(albumID: "a"))] {
            let paused = state(after: [requested("a"), stopped("a", .paused(reason)), .enteredBackground])

            let result = transition(resume, in: paused)

            XCTAssertEqual(startedAlbumIDs(result.effects), [], "\(reason)")
            XCTAssertEqual(result.state.albums["a"]?.pause?.reason, reason, "\(reason)")
            XCTAssertNil(result.state.listHeldBy, "\(reason)")
        }

        let waitingForWiFi = state(after: [requested("a"), stopped("a", .paused(.waitingForWiFi)), .enteredBackground])
        let result = transition(deviceChanged("a", .network), in: waitingForWiFi)
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
        XCTAssertNil(result.state.albums["a"], "a Wi-Fi pause is forgotten, as when its resumed pass stops for the background")
    }

    func testForegroundEventClearsTheBackgroundCondition() {
        let inBackground = state(after: [requested("a"), .enteredBackground])

        let result = transition(.enteredForeground, in: inBackground)

        XCTAssertFalse(result.state.isInBackground)
        XCTAssertEqual(result.effects, [.withdrawStopOfRunningPass(albumID: "a", requestedBecause: .inBackground),
                                        .postStateDidChange(albumIDs: [])],
                       "a pass still on the item it had keeps running")
        XCTAssertEqual(startedAlbumIDs(result.effects), [], "nothing else starts while it runs")

        let afterEnd = state(after: [finished("a")], from: result.state)
        XCTAssertEqual(startedAlbumIDs(transition(requested("b"), in: afterEnd).effects), ["b"], "starts are accepted again")

        let foregroundAlready = transition(.enteredForeground, in: state(after: [requested("a")]))
        XCTAssertEqual(foregroundAlready.effects, [], "nothing to withdraw without a background stop")
    }

    // MARK: - Holds, stops and forgets

    func testHoldStopsTheAlbumAndRefusesItsStart() {
        let running = state(after: [requested("a"), requested("b")])

        let heldRunning = transition(.holdTaken(albumID: "a"), in: running)
        XCTAssertEqual(heldRunning.state.itemWriteHolds, ["a": 1])
        XCTAssertTrue(heldRunning.effects.contains(.requestStopOfRunningPass(albumID: "a", because: .stopRequested)),
                      "the running pass is asked to stop before its next item")
        XCTAssertEqual(heldRunning.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "it runs until its item is done")

        let heldWaiting = transition(.holdTaken(albumID: "b"), in: running)
        XCTAssertEqual(waiting(heldWaiting.state), [], "a waiting album leaves the list")
        XCTAssertNil(heldWaiting.state.albums["b"])
        XCTAssertTrue(heldWaiting.effects.contains(.answerAwaitingCallers(albumID: "b", outcome: .stopped(.stopRequested, MigrationPassReport()))))

        let ended = transition(stopped("a", .stopRequested), in: heldRunning.state)
        XCTAssertEqual(startedAlbumIDs(ended.effects), ["b"], "the next waiting album takes the turn")
        let refused = transition(requested("a"), in: ended.state)
        XCTAssertNil(refused.state.albums["a"], "a start during a hold is refused before it can queue")
        XCTAssertEqual(waiting(refused.state), [])
        XCTAssertEqual(startedAlbumIDs(refused.effects), [])

        let refusedWithNothingRunning = transition(requested("a"), in: state(after: [.holdTaken(albumID: "a")]))
        XCTAssertEqual(startedAlbumIDs(refusedWithNothingRunning.effects), [])
    }

    func testReleasingTheLastHoldAllowsAStart() {
        let held = state(after: [.holdTaken(albumID: "a")])

        let released = transition(.holdReleased(albumID: "a"), in: held)
        XCTAssertEqual(released.state.itemWriteHolds, [:])
        XCTAssertEqual(released.effects, [.postStateDidChange(albumIDs: [])], "releasing starts nothing")

        let started = transition(requested("a"), in: released.state)
        XCTAssertEqual(startedAlbumIDs(started.effects), ["a"])
    }

    func testNestedHoldsNeedEveryRelease() {
        let heldTwice = state(after: [.holdTaken(albumID: "a"), .holdTaken(albumID: "a")])
        XCTAssertEqual(heldTwice.itemWriteHolds, ["a": 2])

        let releasedOnce = transition(.holdReleased(albumID: "a"), in: heldTwice).state
        XCTAssertEqual(releasedOnce.itemWriteHolds, ["a": 1])
        XCTAssertEqual(startedAlbumIDs(transition(requested("a"), in: releasedOnce).effects), [], "one hold is still taken")

        let releasedTwice = transition(.holdReleased(albumID: "a"), in: releasedOnce).state
        XCTAssertEqual(releasedTwice.itemWriteHolds, [:])
        XCTAssertEqual(startedAlbumIDs(transition(requested("a"), in: releasedTwice).effects), ["a"])

        let releasedTooOften = transition(.holdReleased(albumID: "a"), in: releasedTwice)
        XCTAssertEqual(releasedTooOften.state.itemWriteHolds, [:], "a release without a hold changes nothing")
    }

    func testHoldOfOneAlbumLeavesTheOthersAlone() {
        let before = state(after: [requested("a"), requested("b"), .holdTaken(albumID: "c")])

        XCTAssertEqual(waiting(before), ["b"])
        XCTAssertEqual(before.runningAlbumID, "a")
        XCTAssertEqual(startedAlbumIDs(transition(finished("a"), in: before).effects), ["b"])
    }

    func testStopRequestRemovesAWaitingAlbum() {
        let before = state(after: [requested("a"), requested("b"), requested("c")])

        let result = transition(.stopRequested(albumID: "b"), in: before)

        XCTAssertEqual(waiting(result.state), ["c"])
        XCTAssertNil(result.state.albums["b"])
        XCTAssertEqual(result.effects, [.answerAwaitingCallers(albumID: "b", outcome: .stopped(.stopRequested, MigrationPassReport())),
                                        .postStateDidChange(albumIDs: ["b"])])
        XCTAssertEqual(result.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "the running album is not stopped")
    }

    func testStopRequestAsksTheRunningPassToStopAndKeepsItRunningUntilItEnds() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(.stopRequested(albumID: "a"), in: before)

        XCTAssertEqual(result.state, before, "the album runs until its pass ends")
        XCTAssertEqual(result.effects, [.requestStopOfRunningPass(albumID: "a", because: .stopRequested)])
    }

    func testStoppedWaitingAlbumKeepsThePauseItResumedFrom() {
        let before = state(after: [requested("a"), stopped("a", .paused(.accountUnavailable)), requested("b"),
                                   deviceChanged("a", .account)])
        XCTAssertEqual(waiting(before), ["a"])

        let result = transition(.stopRequested(albumID: "a"), in: before)

        XCTAssertEqual(result.state.albums["a"], .paused(folder: folder("a"), reason: .accountUnavailable, bytesStillNeeded: nil))
        XCTAssertEqual(waiting(result.state), [])
    }

    func testForgettingAnAlbumClearsItsPauseHoldAndPlaceInLine() {
        let paused = state(after: [requested("a"), requested("b"), stopped("a", .paused(.waitingForWiFi))])
        XCTAssertEqual(paused.listHeldBy, "a")
        let forgottenHolder = transition(.albumForgotten(albumID: "a"), in: paused)
        XCTAssertNil(forgottenHolder.state.albums["a"], "its pause is forgotten")
        XCTAssertNil(forgottenHolder.state.listHeldBy, "its hold on the list ends")
        XCTAssertEqual(startedAlbumIDs(forgottenHolder.effects), ["b"])

        let behindAnother = state(after: [requested("a"), stopped("a", .paused(.quota)), requested("b"), .quotaRetryCameDue(albumID: "a")])
        XCTAssertEqual(waiting(behindAnother), ["a"])
        let forgottenWaiting = transition(.albumForgotten(albumID: "a"), in: behindAnother)
        XCTAssertEqual(waiting(forgottenWaiting.state), [], "its place in line is given up")
        XCTAssertNil(forgottenWaiting.state.albums["a"], "with the pause it waited with")
        XCTAssertTrue(forgottenWaiting.effects.contains(.answerAwaitingCallers(albumID: "a", outcome: .stopped(.albumNotOnDevice, MigrationPassReport()))))

        let resumed = state(after: [requested("a"), stopped("a", .paused(.quota)), .quotaRetryCameDue(albumID: "a")])
        let forgottenRunning = transition(.albumForgotten(albumID: "a"), in: resumed)
        XCTAssertEqual(forgottenRunning.state.albums["a"], .running(folder: folder("a"), keptPause: nil),
                       "a running album loses its pause and runs on to its end")
    }

    func testEraseCancelsTheRunningPassAndEmptiesTheList() {
        let before = state(after: [requested("a"), requested("b"), requested("c")])

        let result = transition(.erased, in: before)

        XCTAssertEqual(waiting(result.state), [])
        XCTAssertEqual(Array(result.state.albums.keys), ["a"])
        XCTAssertEqual(result.effects, [
            .answerAwaitingCallers(albumID: "b", outcome: .stopped(.erased, MigrationPassReport())),
            .answerAwaitingCallers(albumID: "c", outcome: .stopped(.erased, MigrationPassReport())),
            .cancelRunningPass,
            .removeStoredRequestedAlbumIDs,
            .postStateDidChange(albumIDs: ["a", "b", "c"])
        ])
    }

    // MARK: - Requested albums

    func testUserRequestAddsTheAlbumToTheOrder() {
        let first = transition(requested("a"), in: SchedulerState())
        XCTAssertEqual(first.state.order, ["a"], "a requested album is in the order while it runs")
        XCTAssertEqual(savedAlbumIDs(first.effects), [["a"]])

        let second = transition(requested("b"), in: first.state)
        XCTAssertEqual(second.state.order, ["a", "b"])
        XCTAssertEqual(waiting(second.state), ["b"])

        let again = transition(requested("a"), in: second.state)
        XCTAssertEqual(again.state.order, ["a", "b"], "once")
        XCTAssertEqual(again.effects, [])

        let heldByItemWrite = transition(requested("c"), in: state(after: [.holdTaken(albumID: "c")]))
        XCTAssertEqual(heldByItemWrite.state.order, ["c"], "a request during an item write is kept, though nothing starts")
        XCTAssertEqual(startedAlbumIDs(heldByItemWrite.effects), [])
    }

    func testOneOffStartRunsWithoutJoiningTheOrder() {
        let result = transition(oneOff("a"), in: SchedulerState())

        XCTAssertEqual(startedAlbumIDs(result.effects), ["a"], "the turn is free")
        XCTAssertEqual(result.state.order, [])
        XCTAssertEqual(savedAlbumIDs(result.effects), [], "a one-off is never written to the list")

        let ended = transition(finished("a"), in: result.state)
        XCTAssertEqual(ended.state, SchedulerState())
    }

    func testOneOffStartIsDroppedWhileAnotherAlbumRuns() {
        let running = state(after: [requested("a")])

        let result = transition(oneOff("b"), in: running)

        XCTAssertEqual(result.state, running, "it neither runs nor waits")
        XCTAssertEqual(result.effects, [])
    }

    func testOneOffStartForARequestedAlbumWaitsItsTurn() {
        var before = state(after: [requested("a")])
        before.order = ["a", "b"]

        let result = transition(oneOff("b"), in: before)

        XCTAssertEqual(waiting(result.state), ["b"], "the album was asked for, so it may wait")
        XCTAssertEqual(result.state.order, ["a", "b"])
        XCTAssertEqual(savedAlbumIDs(result.effects), [])
    }

    func testOneOffPassThatPausesAndResumesBehindAnotherAlbumStillGetsItsTurn() {
        let before = state(after: [oneOff("x"), stopped("x", .paused(.accountUnavailable)), requested("a"),
                                   deviceChanged("x", .account)])
        XCTAssertEqual(waiting(before), ["x"])
        XCTAssertEqual(before.order, ["a"])

        let result = transition(finished("a"), in: before)

        XCTAssertEqual(startedAlbumIDs(result.effects), ["x"])
    }

    func testRequestedAlbumsStartBeforeOtherWaitingAlbums() {
        let before = state(after: [oneOff("x"), stopped("x", .paused(.accountUnavailable)), requested("a"),
                                   deviceChanged("x", .account), requested("b")])
        XCTAssertEqual(waiting(before), ["b", "x"])

        XCTAssertEqual(startedAlbumIDs(transition(finished("a"), in: before).effects), ["b"])
    }

    func testPausedAlbumStaysInTheOrder() {
        for reason in Self.deviceWideReasons + [.schemaNotDeployed] {
            let result = transition(stopped("a", .paused(reason)), in: state(after: [requested("a"), requested("b")]))

            XCTAssertEqual(result.state.order, ["a", "b"], "\(reason)")
            XCTAssertEqual(savedAlbumIDs(result.effects), [], "\(reason): nothing to save")
        }
    }

    func testStoppedOrHeldAlbumStaysInTheOrder() {
        let before = state(after: [requested("a"), requested("b")])

        for event in [Event.stopRequested(albumID: "b"), .holdTaken(albumID: "b"), .stopRequested(albumID: "a"),
                      .holdTaken(albumID: "a"), stopped("a", .stopRequested), stopped("a", .locked)] {
            XCTAssertEqual(transition(event, in: before).state.order, ["a", "b"], "\(event)")
        }
    }

    func testBackgroundKeepsTheOrderAndStopsThePass() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(.enteredBackground, in: before)

        XCTAssertEqual(result.state.order, ["a", "b"])
        XCTAssertEqual(savedAlbumIDs(result.effects), [])
        XCTAssertTrue(result.effects.contains(.requestStopOfRunningPass(albumID: "a", because: .inBackground)))
        XCTAssertEqual(waiting(result.state), ["b"], "the waiting album keeps waiting")
        XCTAssertFalse(result.effects.contains { if case .answerAwaitingCallers = $0 { return true } else { return false } })

        let ended = transition(stopped("a", .inBackground), in: result.state)
        XCTAssertEqual(ended.state.order, ["a", "b"], "the stopped album is still requested")
        XCTAssertEqual(startedAlbumIDs(ended.effects), [], "nothing starts in the background")
        XCTAssertEqual(waiting(ended.state), ["b"])
    }

    func testFinishedAlbumLeavesTheOrder() {
        let before = state(after: [requested("a"), requested("b")])

        let forgotten = transition(.albumForgotten(albumID: "a"), in: before)
        XCTAssertEqual(forgotten.state.order, ["b"], "the album is done or deleted")
        XCTAssertEqual(savedAlbumIDs(forgotten.effects), [["b"]])
        XCTAssertEqual(forgotten.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "its pass runs to its end")

        let ended = transition(finished("a"), in: forgotten.state)
        XCTAssertEqual(startedAlbumIDs(ended.effects), ["b"])
        XCTAssertEqual(ended.state.order, ["b"])

        let passOnly = transition(finished("a"), in: before)
        XCTAssertEqual(passOnly.state.order, ["a", "b"], "a pass that tried every item does not by itself end the request")
    }

    func testAlbumWithNoPlanLeavesTheOrder() {
        for stopReason in [StopReason.noPlan, .albumNotOnDevice] {
            let result = transition(stopped("a", stopReason), in: state(after: [requested("a"), requested("b")]))

            XCTAssertEqual(result.state.order, ["b"], "\(stopReason): nothing is left to continue")
            XCTAssertEqual(savedAlbumIDs(result.effects), [["b"]], "\(stopReason)")
            XCTAssertEqual(startedAlbumIDs(result.effects), ["b"], "\(stopReason)")
        }
    }

    // MARK: - Continuing requested albums

    private func albumStepsRun(_ effects: [Effect]) -> [String] {
        effects.compactMap { effect in
            if case .runAlbumStep(let albumID) = effect { return albumID }
            return nil
        }
    }

    private func stepEnded(_ albumID: String, _ result: Scheduler.AlbumStepResult) -> Event {
        .albumStepEnded(albumID: albumID, result: result)
    }

    func testContinueRunsTheAlbumStepForTheFirstRequestedAlbumOnly() {
        let relaunched = SchedulerState(order: ["a", "b", "c"])

        let result = transition(.continueRequested, in: relaunched)

        XCTAssertEqual(albumStepsRun(result.effects), ["a"], "one folder's worth of work, not three")
        XCTAssertEqual(result.state.continuingAlbumID, "a")
        XCTAssertEqual(startedAlbumIDs(result.effects), [], "the album step starts the pass")

        let again = transition(.continueRequested, in: result.state)
        XCTAssertEqual(albumStepsRun(again.effects), [], "nothing more while the album step runs")

        let started = transition(requested("a"), in: result.state)
        XCTAssertEqual(startedAlbumIDs(started.effects), ["a"], "the album step's start takes the turn")
        XCTAssertNil(started.state.continuingAlbumID)
        XCTAssertEqual(started.state.order, ["a", "b", "c"])

        let stepDone = transition(stepEnded("a", .startedPass), in: started.state)
        XCTAssertEqual(albumStepsRun(stepDone.effects), [], "the others wait for the pass to end")
        XCTAssertEqual(startedAlbumIDs(stepDone.effects), [])
    }

    func testContinueStartsNothingForAnAlbumThatWasNotRequested() {
        let before = state(after: [oneOff("x"), stopped("x", .stopRequested)])

        let result = transition(.continueRequested, in: before)

        XCTAssertEqual(albumStepsRun(result.effects), [])
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
    }

    func testContinueDoesNothingWhileAPassIsRunning() {
        let running = state(after: [oneOff("x")], from: SchedulerState(order: ["a", "b"]))

        let result = transition(.continueRequested, in: running)

        XCTAssertEqual(albumStepsRun(result.effects), [])
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
        XCTAssertNil(result.state.continuingAlbumID)
    }

    func testContinueDoesNothingWhileTheListIsHeld() {
        let held = state(after: [requested("a"), stopped("a", .paused(.lowPowerMode))], from: SchedulerState(order: ["a", "b"]))
        XCTAssertEqual(held.listHeldBy, "a")

        let result = transition(.continueRequested, in: held)

        XCTAssertEqual(albumStepsRun(result.effects), [], "the next album would only stop for the same reason")
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
    }

    func testContinueDoesNothingWhileLockedOrInBackground() {
        let inBackground = SchedulerState(order: ["a", "b"], isInBackground: true)

        let result = transition(.continueRequested, in: inBackground)

        XCTAssertEqual(albumStepsRun(result.effects), [])
        XCTAssertEqual(result.state.continuingAlbumID, nil)
    }

    func testPassEndWithAPauseThatDoesNotHoldTheListContinuesWithTheNextAlbum() {
        let running = state(after: [requested("a")], from: SchedulerState(order: ["a", "b"]))

        let ended = transition(stopped("a", .paused(.schemaNotDeployed)), in: running)

        XCTAssertEqual(albumStepsRun(ended.effects), ["b"], "a schema pause hands the turn on")
        XCTAssertNil(ended.state.listHeldBy)

        let later = transition(.continueRequested, in: state(after: [stepEnded("b", .waitsForConditions)], from: ended.state))
        XCTAssertEqual(albumStepsRun(later.effects), ["b"], "the paused album is passed over, not continued")
    }

    func testWaitingAlbumStartsItsPassWithoutAnAlbumStep() {
        let before = state(after: [oneOff("x"), requested("a")], from: SchedulerState(order: ["a", "b"]))
        XCTAssertEqual(waiting(before), ["a"])

        let ended = transition(finished("x"), in: before)
        XCTAssertEqual(startedAlbumIDs(ended.effects), ["a"], "it has its folder already")
        XCTAssertEqual(albumStepsRun(ended.effects), [])

        let next = transition(finished("a"), in: ended.state)
        XCTAssertEqual(albumStepsRun(next.effects), ["b"], "the next requested album has no state yet, so it gets the album step")
    }

    func testPassEndContinuesWithTheNextRequestedAlbum() {
        let running = state(after: [.continueRequested, requested("a"), stepEnded("a", .startedPass)],
                            from: SchedulerState(order: ["a", "b", "c"]))
        XCTAssertEqual(running.runningAlbumID, "a")

        let forgotten = transition(.albumForgotten(albumID: "a"), in: running)
        let ended = transition(finished("a"), in: forgotten.state)

        XCTAssertEqual(albumStepsRun(ended.effects), ["b"], "the album is done: the next requested album continues")
        XCTAssertEqual(ended.state.continuingAlbumID, "b")
        XCTAssertEqual(ended.state.order, ["b", "c"])
    }

    func testPassThatEndsWithoutFinishingItsAlbumIsNotContinuedAgainInTheSameRound() {
        let running = state(after: [.continueRequested, requested("a"), stepEnded("a", .startedPass)],
                            from: SchedulerState(order: ["a", "b"]))

        let ended = transition(stopped("a", .locked), in: running)
        XCTAssertEqual(albumStepsRun(ended.effects), ["b"], "the next album, not the same one again")

        let stepSkipped = transition(stepEnded("b", .startedPass), in: ended.state)
        XCTAssertEqual(albumStepsRun(stepSkipped.effects), [], "each album is tried once per round")
        XCTAssertNil(stepSkipped.state.continuingAlbumID)

        let nextRound = transition(.continueRequested, in: stepSkipped.state)
        XCTAssertEqual(albumStepsRun(nextRound.effects), ["a"], "a new round starts from the head again")
    }

    func testPassEndWithAPauseThatHoldsTheListContinuesNothing() {
        let running = state(after: [.continueRequested, requested("a"), stepEnded("a", .startedPass)],
                            from: SchedulerState(order: ["a", "b"]))

        let ended = transition(stopped("a", .paused(.waitingForWiFi)), in: running)

        XCTAssertEqual(albumStepsRun(ended.effects), [])
        XCTAssertEqual(ended.state.listHeldBy, "a")
    }

    func testAlbumStepThatWaitsForConditionsEndsTheRoundForAlbumsNotStartedYet() {
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a", "b"]))

        let result = transition(stepEnded("a", .waitsForConditions), in: continuing)

        XCTAssertNil(result.state.continuingAlbumID)
        XCTAssertEqual(albumStepsRun(result.effects), [], "the albums behind it would wait for the same conditions")
        XCTAssertEqual(result.state.order, ["a", "b"])

        let nextRound = transition(.continueRequested, in: result.state)
        XCTAssertEqual(albumStepsRun(nextRound.effects), ["a"], "the next round tries it again")
    }

    func testRequestWhileAnAlbumStepRunsWaitsAndStartsWhenTheStepStartsNothing() {
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a"]))

        let asked = transition(requested("b"), in: continuing)
        XCTAssertEqual(startedAlbumIDs(asked.effects), [], "the turn belongs to the album being continued")
        XCTAssertEqual(waiting(asked.state), ["b"])

        let stepDone = transition(stepEnded("a", .waitsForConditions), in: asked.state)
        XCTAssertEqual(startedAlbumIDs(stepDone.effects), ["b"], "a waiting album starts once the album step is over")
    }

    func testForegroundEventContinuesRequestedUpgrades() {
        let stoppedForBackground = state(after: [.continueRequested, requested("a"), stepEnded("a", .startedPass),
                                                 .enteredBackground, stopped("a", .inBackground)],
                                         from: SchedulerState(order: ["a", "b"]))
        XCTAssertEqual(stoppedForBackground.albums, [:])

        let result = transition(.enteredForeground, in: stoppedForBackground)

        XCTAssertEqual(albumStepsRun(result.effects), ["a"], "the album that was stopped for the background continues first")
        XCTAssertEqual(startedAlbumIDs(result.effects), [])
    }

    func testReleasedHoldLetsTheAlbumContinueInTheSameRound() {
        let held = state(after: [.continueRequested, requested("a"), stepEnded("a", .startedPass), .holdTaken(albumID: "a"),
                                 stopped("a", .stopRequested)],
                         from: SchedulerState(order: ["a"]))
        XCTAssertEqual(albumStepsRun(transition(.continueRequested, in: held).effects), [], "an item write holds its passes")

        let released = transition(.holdReleased(albumID: "a"), in: held)

        XCTAssertEqual(albumStepsRun(released.effects), ["a"], "the pass restarts when the hold is released")
    }

    func testForgettingTheAlbumBeingContinuedMovesOn() {
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a", "b"]))

        let result = transition(.albumForgotten(albumID: "a"), in: continuing)

        XCTAssertEqual(result.state.order, ["b"])
        XCTAssertEqual(albumStepsRun(result.effects), ["b"])
    }

    func testEraseForgetsTheAlbumBeingContinued() {
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a", "b"]))

        let result = transition(.erased, in: continuing)

        XCTAssertEqual(result.state, SchedulerState())
        XCTAssertEqual(albumStepsRun(result.effects), [])
    }

    // MARK: - Albums that cannot continue

    func testMissingHeadAlbumIsDroppedAndTheNextContinues() {
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["gone", "b", "c"]))
        XCTAssertEqual(continuing.continuingAlbumID, "gone")

        let result = transition(stepEnded("gone", .nothingToContinue), in: continuing)

        XCTAssertEqual(result.state.order, ["b", "c"], "an album that is no longer on this device leaves the list")
        XCTAssertEqual(savedAlbumIDs(result.effects), [["b", "c"]])
        XCTAssertEqual(albumStepsRun(result.effects), ["b"], "and the next continues in the same launch")
    }

    func testHeadAlbumWithNoLinkedFolderIsDroppedAndTheNextContinues() {
        XCTAssertEqual(Scheduler.AlbumStepResult(whenAlbumIsOnDevice: false, linksAFolder: false), .nothingToContinue)
        XCTAssertEqual(Scheduler.AlbumStepResult(whenAlbumIsOnDevice: true, linksAFolder: false), .nothingToContinue,
                       "an album that links no folder has nothing left on iCloud Drive")
        XCTAssertNil(Scheduler.AlbumStepResult(whenAlbumIsOnDevice: true, linksAFolder: true), "a linked album gets its album step")

        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["unlinked", "b"]))
        let result = transition(stepEnded("unlinked", .nothingToContinue), in: continuing)
        XCTAssertEqual(result.state.order, ["b"])
        XCTAssertEqual(albumStepsRun(result.effects), ["b"])
    }

    func testAlbumWhoseFolderIsGoneIsFinished() {
        // The finish forgets the album, which takes it out of the order, while
        // its album step is still in flight; the step then reports nothing left.
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["finishedElsewhere", "b"]))

        let forgotten = transition(.albumForgotten(albumID: "finishedElsewhere"), in: continuing)
        XCTAssertEqual(forgotten.state.order, ["b"])
        XCTAssertEqual(albumStepsRun(forgotten.effects), ["b"], "the next album continues at once")

        let reported = transition(stepEnded("finishedElsewhere", .nothingToContinue), in: forgotten.state)
        XCTAssertEqual(reported.state, forgotten.state, "the late report changes nothing")
        XCTAssertEqual(reported.effects, [])
    }

    func testFullyDeferredAlbumLeavesTheOrderAndTheNextStarts() {
        let running = state(after: [requested("a"), requested("b")])
        let onlyDeferredLeft = Event.passEnded(
            albumID: "a",
            ending: Scheduler.PassEnding(outcome: .finished(MigrationPassReport()), leavesOnlyDeferredItems: true))

        let result = transition(onlyDeferredLeft, in: running)

        XCTAssertEqual(result.state.order, ["b"], "the album stays readable from its folder but is no longer continued")
        XCTAssertEqual(savedAlbumIDs(result.effects), [["b"]])
        XCTAssertEqual(startedAlbumIDs(result.effects), ["b"])

        let stillMoving = transition(finished("a"), in: running)
        XCTAssertEqual(stillMoving.state.order, ["a", "b"], "a pass that left items it can still move keeps the request")

        let stoppedWithDeferrals = Event.passEnded(
            albumID: "a",
            ending: Scheduler.PassEnding(outcome: .stopped(.stopRequested, MigrationPassReport()), leavesOnlyDeferredItems: true))
        XCTAssertEqual(transition(stoppedWithDeferrals, in: running).state.order, ["a", "b"], "only a pass that tried every item decides")
    }

    func testUnrecoverableAlbumStepSkipMovesOnWithoutLooping() {
        for reason in [ICloudDriveAlbumMigration.MigrationSkipReason.albumNotFound, .recordGone(albumID: "a"), .deletePending(albumID: "a"),
                       .noMatchingKey(albumID: "a"), .markerUnreadable] {
            XCTAssertEqual(Scheduler.AlbumStepResult(skipReason: reason), .cannotContinueThisLaunch, "\(reason)")
        }
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a", "b"]))

        let skipped = transition(stepEnded("a", .cannotContinueThisLaunch), in: continuing)
        XCTAssertEqual(skipped.state.order, ["a", "b"], "the album stays in the list")
        XCTAssertEqual(albumStepsRun(skipped.effects), ["b"], "the album behind it starts in the same launch")

        var current = skipped.state
        var stepsForA = 0
        let laterEvents: [Event] = [stepEnded("b", .startedPass), .continueRequested, stepEnded("b", .cannotContinueThisLaunch),
                                    .enteredBackground, .enteredForeground, .continueRequested, .continueRequested]
        for event in laterEvents {
            let result = transition(event, in: current)
            stepsForA += albumStepsRun(result.effects).filter { $0 == "a" }.count
            current = result.state
        }
        XCTAssertEqual(stepsForA, 0, "it is not tried again in this launch, whatever starts a new round")
        XCTAssertEqual(current.order, ["a", "b"])

        let askedAgain = transition(requested("a"), in: current)
        XCTAssertEqual(startedAlbumIDs(askedAgain.effects), ["a"], "the user asking again runs it")
        let afterAsking = state(after: [stopped("a", .stopRequested), .continueRequested], from: askedAgain.state)
        XCTAssertEqual(afterAsking.continuingAlbumID, "a", "and lets it continue again")
    }

    func testRecoverableAlbumStepSkipWaits() {
        for reason in [ICloudDriveAlbumMigration.MigrationSkipReason.offline, .locked, .accountUnavailable, .inBackground, .markerEvicted,
                       .iCloudDriveUnavailable] {
            XCTAssertEqual(Scheduler.AlbumStepResult(skipReason: reason), .waitsForConditions, "\(reason)")
        }
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a", "b"]))

        let waited = transition(stepEnded("a", .waitsForConditions), in: continuing)

        XCTAssertEqual(albumStepsRun(waited.effects), [], "the album behind it does not jump ahead")
        XCTAssertEqual(waited.state.order, ["a", "b"])
        XCTAssertEqual(albumStepsRun(transition(.continueRequested, in: waited.state).effects), ["a"], "the next round tries it again")
    }

    func testAlbumStepSkipThatMayClearSoonMovesOnForThisRoundOnly() {
        for reason in [ICloudDriveAlbumMigration.MigrationSkipReason.markerConflicted, .recordNotVisibleYet(albumID: "a"),
                       .markerChanged(albumID: "a"), .failed(step: "saveAlbum", error: "x")] {
            XCTAssertEqual(Scheduler.AlbumStepResult(skipReason: reason), .cannotContinueThisRound, "\(reason)")
        }
        let continuing = state(after: [.continueRequested], from: SchedulerState(order: ["a", "b"]))

        let skipped = transition(stepEnded("a", .cannotContinueThisRound), in: continuing)
        XCTAssertEqual(albumStepsRun(skipped.effects), ["b"])

        let nextRound = state(after: [stepEnded("b", .cannotContinueThisRound), .continueRequested], from: skipped.state)
        XCTAssertEqual(nextRound.continuingAlbumID, "a", "the next round starts from it again")
    }

    // MARK: - Pausing at the user's request

    func testUserPauseRemovesTheAlbumFromTheOrder() {
        let before = state(after: [requested("a"), requested("b"), requested("c")])

        let result = transition(.userPaused(albumID: "b"), in: before)

        XCTAssertEqual(result.state.order, ["a", "c"])
        XCTAssertEqual(savedAlbumIDs(result.effects), [["a", "c"]], "the stored list no longer holds it")
        XCTAssertNil(result.state.albums["b"], "it no longer waits")
        XCTAssertTrue(result.effects.contains(.answerAwaitingCallers(albumID: "b", outcome: .stopped(.stopRequested, MigrationPassReport()))))
        XCTAssertEqual(result.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "the running album is not touched")

        let pausedHolder = state(after: [requested("a"), requested("b"), stopped("a", .paused(.quota))])
        XCTAssertEqual(pausedHolder.listHeldBy, "a")
        let unheld = transition(.userPaused(albumID: "a"), in: pausedHolder)
        XCTAssertEqual(unheld.state.order, ["b"])
        XCTAssertNil(unheld.state.albums["a"], "its pause goes with it, so nothing resumes it")
        XCTAssertEqual(startedAlbumIDs(unheld.effects), ["b"], "and it no longer holds the others")
    }

    func testUserPauseOfTheRunningAlbumStartsTheNext() {
        let before = state(after: [requested("a"), requested("b")])

        let paused = transition(.userPaused(albumID: "a"), in: before)
        XCTAssertEqual(paused.state.order, ["b"])
        XCTAssertTrue(paused.effects.contains(.requestStopOfRunningPass(albumID: "a", because: .stopRequested)),
                      "the pass stops before its next item")
        XCTAssertEqual(paused.state.albums["a"], .running(folder: folder("a"), keptPause: nil), "its item in flight finishes")
        XCTAssertEqual(startedAlbumIDs(paused.effects), [])

        let ended = transition(stopped("a", .stopRequested), in: paused.state)
        XCTAssertEqual(startedAlbumIDs(ended.effects), ["b"], "the next requested album starts")
        XCTAssertNil(ended.state.albums["a"])

        let endedWithAPause = transition(stopped("a", .paused(.waitingForWiFi)), in: paused.state)
        XCTAssertNil(endedWithAPause.state.albums["a"], "a pause its last item ran into is not kept: nothing may resume it")
        XCTAssertNil(endedWithAPause.state.listHeldBy)
        XCTAssertEqual(startedAlbumIDs(endedWithAPause.effects), ["b"])
    }

    func testUserPausedAlbumIsNotContinued() {
        let paused = state(after: [requested("a"), requested("b"), .userPaused(albumID: "a"), stopped("a", .stopRequested),
                                   finished("b")])

        var current = paused
        for event in [Event.continueRequested, .enteredBackground, .enteredForeground, .continueRequested] {
            let result = transition(event, in: current)
            XCTAssertFalse(albumStepsRun(result.effects).contains("a"), "\(event)")
            XCTAssertFalse(startedAlbumIDs(result.effects).contains("a"), "\(event)")
            current = result.state
        }
        XCTAssertFalse(current.order.contains("a"), "it is not in the list a relaunch reads")

        let askedAgain = transition(requested("a"), in: SchedulerState(order: ["b"]))
        XCTAssertEqual(askedAgain.state.order, ["b", "a"], "a tap to resume asks for it again, at the back")
    }

    func testAskingAgainWhileThePausedPassStillRunsLetsItRunOn() {
        let stopping = state(after: [requested("a"), .userPaused(albumID: "a")])
        XCTAssertEqual(stopping.albumIDStoppingAtUserRequest, "a")

        let result = transition(requested("a"), in: stopping)

        XCTAssertEqual(result.state.order, ["a"])
        XCTAssertNil(result.state.albumIDStoppingAtUserRequest)
        XCTAssertTrue(result.effects.contains(.withdrawStopOfRunningPass(albumID: "a", requestedBecause: .stopRequested)))

        let heldToo = state(after: [requested("a"), .holdTaken(albumID: "a"), .userPaused(albumID: "a")])
        let refused = transition(requested("a"), in: heldToo)
        XCTAssertFalse(refused.effects.contains(.withdrawStopOfRunningPass(albumID: "a", requestedBecause: .stopRequested)),
                       "an item write still wants the pass stopped")
    }

    // MARK: - The stored list

    private func savedAlbumIDs(_ effects: [Effect]) -> [[String]] {
        effects.compactMap { effect in
            if case .saveRequestedAlbumIDs(let albumIDs) = effect { return albumIDs }
            return nil
        }
    }

    func testOrderChangeEmitsSaveEffect() {
        let first = transition(requested("a"), in: SchedulerState())
        XCTAssertEqual(savedAlbumIDs(first.effects), [["a"]])

        let second = transition(requested("b"), in: first.state)
        XCTAssertEqual(savedAlbumIDs(second.effects), [["a", "b"]], "the whole order is saved, first in first out")

        let unchanged = transition(requested("b"), in: second.state)
        XCTAssertEqual(savedAlbumIDs(unchanged.effects), [])

        for event in [Event.stopRequested(albumID: "b"), .holdTaken(albumID: "a"), .enteredBackground,
                      stopped("a", .paused(.quota)), finished("a"), oneOff("c")] {
            XCTAssertEqual(savedAlbumIDs(transition(event, in: second.state).effects), [], "\(event) leaves the order alone")
        }

        let forgotten = transition(.albumForgotten(albumID: "a"), in: second.state)
        XCTAssertEqual(savedAlbumIDs(forgotten.effects), [["b"]])

        let emptied = transition(.albumForgotten(albumID: "b"), in: forgotten.state)
        XCTAssertEqual(savedAlbumIDs(emptied.effects), [[]], "an order that empties is saved empty")
        XCTAssertFalse(emptied.effects.contains(.removeStoredRequestedAlbumIDs))
    }

    func testEraseRemovesTheStoredList() {
        let before = state(after: [requested("a"), requested("b")])

        let result = transition(.erased, in: before)

        XCTAssertTrue(result.effects.contains(.removeStoredRequestedAlbumIDs))
        XCTAssertEqual(savedAlbumIDs(result.effects), [], "the file is removed, not saved empty")
        XCTAssertEqual(result.state.order, [])

        let withNothingStored = transition(.erased, in: SchedulerState())
        XCTAssertEqual(withNothingStored.effects, [.removeStoredRequestedAlbumIDs], "an erase removes the file whatever the order")
    }

    func testStoredAlbumIsContinuedInItsPlaceAndDoesNotBlockTheWaitingAlbums() {
        let loaded = SchedulerState(order: ["stored"])
        let before = state(after: [requested("a"), requested("b")], from: loaded)
        XCTAssertEqual(before.order, ["stored", "a", "b"])

        let ended = transition(finished("a"), in: before)
        XCTAssertEqual(albumStepsRun(ended.effects), ["stored"], "it was asked for first")
        XCTAssertEqual(ended.state.order, ["stored", "a", "b"])

        let stepOver = transition(stepEnded("stored", .waitsForConditions), in: ended.state)
        XCTAssertEqual(startedAlbumIDs(stepOver.effects), ["b"], "an album step that starts nothing lets the waiting album go")

        let asked = transition(requested("stored"), in: before)
        XCTAssertEqual(asked.state.order, ["stored", "a", "b"], "a stored album that is asked for keeps its one place")
        XCTAssertEqual(asked.state.albums["stored"], .waiting(folder: folder("stored"), keptPause: nil))
        XCTAssertEqual(startedAlbumIDs(transition(finished("a"), in: asked.state).effects), ["stored"], "and its turn comes first")

        let forgotten = transition(.albumForgotten(albumID: "stored"), in: before)
        XCTAssertEqual(forgotten.state.order, ["a", "b"])
    }

    // MARK: - Erase

    func testEraseEmptiesTheState() {
        var before = state(after: [requested("a"), requested("b"), stopped("a", .paused(.lowPowerMode)),
                                   requested("c"), requested("d")])
        XCTAssertEqual(before.runningAlbumID, "c")
        XCTAssertEqual(waiting(before), ["b", "d"])
        before.listHeldBy = "a"

        let result = transition(.erased, in: before)

        XCTAssertEqual(waiting(result.state), [], "nothing waits")
        XCTAssertNil(result.state.listHeldBy)
        XCTAssertEqual(result.state.albums, ["c": .running(folder: folder("c"), keptPause: nil)],
                       "only the pass in flight is left, until it ends")
        XCTAssertTrue(result.effects.contains(.cancelRunningPass))
        XCTAssertTrue(result.effects.contains(.answerAwaitingCallers(albumID: "b", outcome: .stopped(.erased, MigrationPassReport()))))
        XCTAssertTrue(result.effects.contains(.answerAwaitingCallers(albumID: "d", outcome: .stopped(.erased, MigrationPassReport()))))
        XCTAssertEqual(startedAlbumIDs(result.effects), [])

        let afterEnd = transition(stopped("c", .erased), in: result.state)
        XCTAssertEqual(afterEnd.state, SchedulerState(), "the cancelled pass ending leaves nothing")
        XCTAssertEqual(startedAlbumIDs(afterEnd.effects), [])
    }

    func testEraseWithNothingRunningCancelsNothing() {
        let before = state(after: [requested("a"), stopped("a", .paused(.quota))])

        let result = transition(.erased, in: before)

        XCTAssertEqual(result.state, SchedulerState())
        XCTAssertFalse(result.effects.contains(.cancelRunningPass))
    }

    // MARK: - Purity

    func testTheSameStateAndEventGiveTheSameTransition() {
        let before = state(after: [requested("a"), requested("b"), requested("c")])

        XCTAssertEqual(transition(finished("a"), in: before), transition(finished("a"), in: before))
    }

    func testAnEventThatChangesNothingPostsNothing() {
        let before = state(after: [requested("a"), requested("b")])

        for event in [Event.holdReleased(albumID: "z"), .stopRequested(albumID: "z"), .albumForgotten(albumID: "z"),
                      .passMadeProgress(albumID: "a"), .enteredForeground, finished("z")] {
            let result = transition(event, in: before)
            XCTAssertEqual(result.state, before, "\(event)")
            XCTAssertEqual(result.effects, [], "\(event)")
        }
    }

    // MARK: - Running passes

    /// A scheduler of its own, with a fake pass runner and device state.
    @MainActor
    private func makeHarness() -> SchedulerHarness { SchedulerHarness() }

    @MainActor
    func testStartEffectRunsThePassRunnerOnce() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")

        XCTAssertEqual(harness.requestPassStart("a"), .started)
        try await harness.waitUntil("the pass runs") { harness.runner.executedAlbumIDs == ["a"] }
        XCTAssertTrue(harness.scheduler.isRunning(albumID: "a"))

        XCTAssertEqual(harness.requestPassStart("a"), .refused, "a pass is already running for the album")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "one start effect, one pass")
        XCTAssertEqual(harness.runner.executedFolders, [folder("a")])
        XCTAssertTrue(harness.isIdle)
    }

    @MainActor
    func testWaitingAlbumRunsWhenTheRunningPassEnds() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")

        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        XCTAssertEqual(harness.requestPassStart("c"), .queued)
        XCTAssertEqual(harness.requestPassStart("b"), .queued, "a second start for a waiting album changes nothing")
        try await harness.waitUntil("the first pass runs") { harness.runner.executedAlbumIDs == ["a"] }
        XCTAssertTrue(harness.scheduler.isWaiting(albumID: "b"))

        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("every pass ends") { harness.isIdle }

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "b", "c"], "one at a time, first in first out")
        XCTAssertEqual(harness.runner.mostPassesRunningAtOnce, 1)
    }

    @MainActor
    func testAwaitingCallerGetsThePassOutcome() async throws {
        let harness = makeHarness()
        let stoppedWithoutPlan = MigrationRunOutcome.stopped(.noPlan, MigrationPassReport())
        harness.runner.ends["a"] = .init(outcome: stoppedWithoutPlan)
        var report = MigrationPassReport()
        report.deleted = ["record"]
        harness.runner.ends["b"] = .init(outcome: .finished(report))

        let outcomeOfA = await harness.runPassAndAwaitOutcome("a")
        XCTAssertEqual(outcomeOfA, stoppedWithoutPlan, "the caller that started the pass gets how it ended")

        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        let waitingCaller = Task { @MainActor in await harness.runPassAndAwaitOutcome("b") }
        try await harness.waitUntil("b waits") { harness.scheduler.isWaiting(albumID: "b") }
        harness.runner.releasePass(ofAlbumID: "a")

        let outcomeOfB = await waitingCaller.value
        XCTAssertEqual(outcomeOfB, .finished(report), "a caller that waited gets the outcome of the pass run at its turn")
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "a", "b"])
    }

    @MainActor
    func testAwaitingCallerOfAnAlbumAlreadyRunningIsToldSo() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)

        let outcome = await harness.runPassAndAwaitOutcome("a")

        XCTAssertEqual(outcome, .alreadyRunning)
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testAwaitingCallerOfARemovedAlbumGetsWhyItStopped() async throws {
        let removals: [(StopReason, @MainActor (ICloudDriveUpgradeScheduler) -> Void)] = [
            (.stopRequested, { $0.requestStop(albumID: "b") }),
            (.albumNotOnDevice, { $0.forgetAlbum(albumID: "b") }),
            (.erased, { $0.emptyStateForErase() })
        ]
        for (stopReason, removeAlbum) in removals {
            let harness = makeHarness()
            harness.runner.holdPass(ofAlbumID: "a")
            XCTAssertEqual(harness.requestPassStart("a"), .started)
            let waitingCaller = Task { @MainActor in await harness.runPassAndAwaitOutcome("b") }
            try await harness.waitUntil("b waits") { harness.scheduler.isWaiting(albumID: "b") }

            removeAlbum(harness.scheduler)

            let outcome = await waitingCaller.value
            XCTAssertEqual(outcome, .stopped(stopReason, MigrationPassReport()))
            XCTAssertFalse(harness.scheduler.isWaiting(albumID: "b"))
            harness.runner.releasePass(ofAlbumID: "a")
            try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
            XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "\(stopReason): the removed album never runs")
        }
    }

    @MainActor
    func testStopRequestIsSeenByTheRunningPassAndAwaitedToItsEnd() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        try await harness.waitUntil("the pass runs") { harness.runner.controls["a"] != nil }
        let control = try XCTUnwrap(harness.runner.controls["a"])
        XCTAssertFalse(control.isStopRequested())

        harness.scheduler.requestStop(albumID: "a")
        XCTAssertTrue(control.isStopRequested(), "the pass is asked to stop before its next item")
        XCTAssertTrue(harness.scheduler.isRunning(albumID: "a"), "it runs until its item in flight is done")

        let waitingForEnd = Task { @MainActor in await harness.scheduler.awaitPassEnd(albumID: "a") }
        harness.runner.releasePass(ofAlbumID: "a")
        await waitingForEnd.value
        XCTAssertFalse(harness.scheduler.isRunning(albumID: "a"))

        harness.runner.holdPass(ofAlbumID: "b")
        XCTAssertEqual(harness.requestPassStart("b"), .started)
        try await harness.waitUntil("the next pass runs") { harness.runner.controls["b"] != nil }
        XCTAssertEqual(harness.runner.controls["b"]?.isStopRequested(), false, "a stop request does not outlive its pass")
        harness.runner.releasePass(ofAlbumID: "b")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testCancellingTheCallerCancelsOnlyThePassItStarted() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        let startingCaller = Task { @MainActor in await harness.runPassAndAwaitOutcome("a") }
        try await harness.waitUntil("the pass runs") { harness.runner.executedAlbumIDs == ["a"] }
        let waitingCaller = Task { @MainActor in await harness.runPassAndAwaitOutcome("b") }
        try await harness.waitUntil("b waits") { harness.scheduler.isWaiting(albumID: "b") }

        waitingCaller.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.runner.cancelledAlbumIDs, [], "a caller that only waits cancels nothing")

        startingCaller.cancel()
        try await harness.waitUntil("the pass is cancelled") { harness.runner.cancelledAlbumIDs == ["a"] }
        _ = await startingCaller.value
        _ = await waitingCaller.value
        try await harness.waitUntil("every pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testBackgroundNotificationStopsThePassAndAnswersWithTheBackground() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        harness.runner.ends["a"] = .init(outcome: .stopped(.stopRequested, MigrationPassReport()))
        let startingCaller = Task { @MainActor in await harness.runPassAndAwaitOutcome("a") }
        try await harness.waitUntil("the pass runs") { harness.runner.controls["a"] != nil }
        XCTAssertEqual(harness.requestPassStart("b"), .queued)

        harness.postDidEnterBackground()

        XCTAssertEqual(harness.runner.controls["a"]?.isStopRequested(), true, "the stop lands at the lifecycle event")
        harness.runner.releasePass(ofAlbumID: "a")
        let outcomeOfA = await startingCaller.value
        XCTAssertEqual(outcomeOfA, .stopped(.inBackground, MigrationPassReport()), "the caller learns why the pass was stopped")
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "no waiting album starts in the background")
        XCTAssertTrue(harness.scheduler.isWaiting(albumID: "b"), "it keeps waiting")
        XCTAssertEqual(harness.scheduler.state.order, ["a", "b"], "both are still requested")

        XCTAssertEqual(harness.requestPassStart("c"), .refused)
        let outcomeOfC = await harness.runPassAndAwaitOutcome("c")
        XCTAssertEqual(outcomeOfC, .stopped(.inBackground, MigrationPassReport()))
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"])

        harness.postWillEnterForeground()
        try await harness.waitUntil("both carry on") { harness.runner.executedAlbumIDs == ["a", "a", "b"] }
        XCTAssertEqual(harness.albumStepsRun, ["a"], "the stopped album continues first, then the one that waited")
        try await harness.waitUntil("they end") { harness.isIdle }
    }

    @MainActor
    func testForegroundNotificationLetsAPassStillOnItsItemRunOn() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        try await harness.waitUntil("the pass runs") { harness.runner.controls["a"] != nil }

        harness.postDidEnterBackground()
        XCTAssertEqual(harness.runner.controls["a"]?.isStopRequested(), true)
        harness.postWillEnterForeground()
        XCTAssertEqual(harness.runner.controls["a"]?.isStopRequested(), false, "the stop was only for the background")
        XCTAssertFalse(harness.scheduler.state.isInBackground)

        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
        XCTAssertEqual(harness.requestPassStart("b"), .started, "starts are accepted in the foreground")
        try await harness.waitUntil("the pass ends") { harness.isIdle }
    }

    @MainActor
    func testForegroundDoesNotWithdrawAStopAskedForAnotherReason() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        try await harness.waitUntil("the pass runs") { harness.runner.controls["a"] != nil }

        harness.scheduler.requestStop(albumID: "a")
        harness.postDidEnterBackground()
        harness.postWillEnterForeground()

        XCTAssertEqual(harness.runner.controls["a"]?.isStopRequested(), true)
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testPassThatStopsForTheBackgroundRecordsTheBackground() async throws {
        let harness = makeHarness()
        harness.scheduler.runAlbumStepForRequestedAlbum = nil
        harness.runner.ends["a"] = .init(outcome: .stopped(.inBackground, MigrationPassReport()))

        let outcome = await harness.runPassAndAwaitOutcome("a")

        XCTAssertEqual(outcome, .stopped(.inBackground, MigrationPassReport()))
        XCTAssertTrue(harness.scheduler.state.isInBackground, "the pass found the app in the background before any event said so")
        XCTAssertEqual(harness.requestPassStart("b"), .refused)
        harness.postWillEnterForeground()
        XCTAssertEqual(harness.requestPassStart("b"), .started)
        try await harness.waitUntil("the pass ends") { harness.isIdle }
    }

    @MainActor
    func testStateChangePostsOneNotification() async throws {
        let harness = makeHarness()
        let posts = harness.recordStateDidChangePosts()
        harness.runner.holdPass(ofAlbumID: "a")

        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(posts.changedAlbumIDs, [["a"]], "a start is one post")
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        XCTAssertEqual(posts.changedAlbumIDs, [["a"], ["b"]], "joining the list is one post")
        harness.scheduler.forgetAlbum(albumID: "b")
        XCTAssertEqual(posts.changedAlbumIDs, [["a"], ["b"], ["b"]], "leaving the list is one post")

        XCTAssertEqual(harness.requestPassStart("c"), .queued)
        harness.pauseNextPass(ofAlbumID: "a", for: .schemaNotDeployed)
        harness.runner.holdPass(ofAlbumID: "c")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("c runs") { harness.scheduler.isRunning(albumID: "c") }
        XCTAssertEqual(posts.changedAlbumIDs.last, ["a", "c"],
                       "a pass that ends paused and hands the turn on is one post naming both albums")
        XCTAssertEqual(posts.changedAlbumIDs.count, 5)

        harness.scheduler.takeItemWriteHold(albumID: "z")
        XCTAssertEqual(posts.changedAlbumIDs.count, 5, "a change for no album is not posted on the albums' center")
        harness.scheduler.releaseItemWriteHold(albumID: "z")
        harness.runner.releasePass(ofAlbumID: "c")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testStateChangeForNoAlbumIsPostedOnTheDefaultCenter() {
        let harness = makeHarness()
        var posts: [[String]] = []
        let observer = NotificationCenter.default.addObserver(forName: ICloudDriveUpgradeScheduler.stateDidChange,
                                                              object: nil, queue: nil) { note in
            posts.append(note.userInfo?[ICloudDriveUpgradeScheduler.changedAlbumIDsKey] as? [String] ?? ["missing"])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let albumID = "hold-\(UUID().uuidString)"

        harness.scheduler.takeItemWriteHold(albumID: albumID)
        harness.scheduler.releaseItemWriteHold(albumID: albumID)

        XCTAssertEqual(posts, [[], []])
    }

    @MainActor
    func testUnchangedStatePostsNothing() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        let posts = harness.recordStateDidChangePosts()

        XCTAssertEqual(harness.requestPassStart("a"), .refused)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        harness.scheduler.requestStop(albumID: "unknown")
        harness.scheduler.forgetAlbum(albumID: "unknown")
        harness.scheduler.releaseItemWriteHold(albumID: "unknown")
        harness.postWillEnterForeground()
        harness.postPowerChange()
        harness.scheduler.requestStop(albumID: "a")

        XCTAssertEqual(posts.changedAlbumIDs, [], "none of these changes the state")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("every pass ends") { harness.isIdle }
    }

    // MARK: - Pauses

    @MainActor
    func testPausedAlbumResumesWhenLowPowerModeTurnsOff() async throws {
        let harness = makeHarness()
        harness.isLowPowerModeEnabled = true
        harness.pauseNextPass(ofAlbumID: "a", for: .lowPowerMode)

        let outcome = await harness.runPassAndAwaitOutcome("a")
        XCTAssertEqual(outcome, .stopped(.paused(.lowPowerMode), MigrationPassReport()))
        XCTAssertEqual(harness.scheduler.pauseReason(albumID: "a"), .lowPowerMode)
        XCTAssertTrue(harness.scheduler.isActive(albumID: "a"))
        XCTAssertFalse(harness.scheduler.isRunning(albumID: "a"))

        harness.postPowerChange()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "nothing resumes while Low Power Mode is on")

        harness.isLowPowerModeEnabled = false
        harness.letNextPassFinish(ofAlbumID: "a")
        harness.postPowerChange()
        try await harness.waitUntil("the album resumes and finishes") { harness.isIdle }

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "a"])
        XCTAssertNil(harness.scheduler.pauseReason(albumID: "a"))
    }

    @MainActor
    func testThermalPauseFollowsTheThermalStateUntilItClears() async throws {
        let harness = makeHarness()
        harness.thermalState = .serious
        harness.pauseNextPass(ofAlbumID: "a", for: .thermalState(.serious))
        _ = await harness.runPassAndAwaitOutcome("a")

        harness.thermalState = .critical
        harness.postThermalChange()
        try await harness.waitUntil("the reason follows the thermal state") {
            harness.scheduler.pauseReason(albumID: "a") == .thermalState(.critical)
        }
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"])

        harness.thermalState = .nominal
        harness.letNextPassFinish(ofAlbumID: "a")
        harness.postThermalChange()
        try await harness.waitUntil("the album resumes") { harness.runner.executedAlbumIDs == ["a", "a"] }
    }

    @MainActor
    func testWiFiPauseResumesOnlyOnAnUnmeteredNetwork() async throws {
        let harness = makeHarness()
        harness.isOnUnmeteredNetwork = false
        harness.pauseNextPass(ofAlbumID: "a", for: .waitingForWiFi)
        _ = await harness.runPassAndAwaitOutcome("a")
        XCTAssertEqual(harness.scheduler.pauseReason(albumID: "a"), .waitingForWiFi)

        harness.postNetworkChange()
        harness.postPowerChange()
        harness.postAccountChange()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "still off Wi-Fi")

        harness.isOnUnmeteredNetwork = true
        harness.letNextPassFinish(ofAlbumID: "a")
        harness.postNetworkChange()
        try await harness.waitUntil("the album resumes and finishes") { harness.isIdle }
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "a"])
    }

    @MainActor
    func testAccountPauseResumesWhenTheAccountChanges() async throws {
        let harness = makeHarness()
        harness.pauseNextPass(ofAlbumID: "a", for: .accountUnavailable)
        _ = await harness.runPassAndAwaitOutcome("a")

        harness.letNextPassFinish(ofAlbumID: "a")
        harness.postAccountChange()

        try await harness.waitUntil("the album resumes and finishes") { harness.isIdle }
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "a"])
    }

    @MainActor
    func testQuotaPauseRunsThePassAgainWhenItsRetryComesDue() async throws {
        let harness = makeHarness()
        harness.pauseNextPass(ofAlbumID: "a", for: .quota, bytesStillNeeded: 42, retryAfter: 60)

        _ = await harness.runPassAndAwaitOutcome("a")

        XCTAssertEqual(harness.scheduler.pauseReason(albumID: "a"), .quota)
        XCTAssertEqual(harness.scheduler.bytesStillNeededWhilePausedForQuota(albumID: "a"), 42)
        XCTAssertEqual(harness.scheduledRetries.map(\.delay), [60])
        harness.postPowerChange()
        harness.postAccountChange()
        harness.postNetworkChange()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "only the retry resumes a full iCloud")

        harness.letNextPassFinish(ofAlbumID: "a")
        harness.scheduledRetries[0].retry()
        try await harness.waitUntil("the album resumes and finishes") { harness.isIdle }

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "a"])
        XCTAssertNil(harness.scheduler.bytesStillNeededWhilePausedForQuota(albumID: "a"))
    }

    @MainActor
    func testSchemaPauseIsNeverResumed() async throws {
        let harness = makeHarness()
        harness.pauseNextPass(ofAlbumID: "a", for: .schemaNotDeployed)
        _ = await harness.runPassAndAwaitOutcome("a")

        harness.postPowerChange()
        harness.postAccountChange()
        harness.postNetworkChange()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"])
        XCTAssertEqual(harness.scheduler.pauseReason(albumID: "a"), .schemaNotDeployed)
        XCTAssertEqual(harness.scheduledRetries.count, 0)
    }

    @MainActor
    func testDeviceStateIsObservedOnlyWhileAnAlbumIsPaused() async throws {
        let harness = makeHarness()
        harness.pauseNextPass(ofAlbumID: "a", for: .accountUnavailable)
        _ = await harness.runPassAndAwaitOutcome("a")
        XCTAssertTrue(harness.observer.isObserving)

        harness.scheduler.forgetAlbum(albumID: "a")
        XCTAssertFalse(harness.observer.isObserving, "nothing is paused")
        harness.postAccountChange()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"], "a forgotten album is not resumed")
    }

    @MainActor
    func testDeviceWidePauseHoldsTheListUntilThePausedAlbumResumes() async throws {
        let harness = makeHarness()
        harness.isLowPowerModeEnabled = true
        harness.runner.holdPass(ofAlbumID: "a")
        harness.pauseNextPass(ofAlbumID: "a", for: .lowPowerMode)
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("a pauses") { harness.scheduler.pauseReason(albumID: "a") == .lowPowerMode }
        XCTAssertTrue(harness.scheduler.isWaiting(albumID: "b"), "the list is held")
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a"])

        harness.isLowPowerModeEnabled = false
        harness.letNextPassFinish(ofAlbumID: "a")
        harness.postPowerChange()
        try await harness.waitUntil("both albums finish") { harness.isIdle }

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "a", "b"], "the paused album resumes first, then the list goes on")
    }

    @MainActor
    func testRefusedResumeOfTheHolderLetsTheListGoOn() async throws {
        let harness = makeHarness()
        harness.isLowPowerModeEnabled = true
        harness.runner.holdPass(ofAlbumID: "a")
        harness.pauseNextPass(ofAlbumID: "a", for: .lowPowerMode)
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("a pauses") { harness.scheduler.pauseReason(albumID: "a") == .lowPowerMode }

        harness.scheduler.takeItemWriteHold(albumID: "a")
        harness.isLowPowerModeEnabled = false
        harness.postPowerChange()
        try await harness.waitUntil("b runs") { harness.runner.executedAlbumIDs == ["a", "b"] }
        try await harness.waitUntil("b finishes") { !harness.scheduler.hasRunningPass }

        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "b"], "the held album did not start")
        XCTAssertEqual(harness.requestPassStart("a"), .refused, "an item write still holds its passes")
        harness.scheduler.releaseItemWriteHold(albumID: "a")
    }

    @MainActor
    func testEachPauseChangeIsPosted() async throws {
        let harness = makeHarness()
        harness.thermalState = .serious
        harness.pauseNextPass(ofAlbumID: "a", for: .thermalState(.serious))
        _ = await harness.runPassAndAwaitOutcome("a")
        let posts = harness.recordStateDidChangePosts()

        harness.thermalState = .critical
        harness.postThermalChange()
        try await harness.waitUntil("the reason changes") { harness.scheduler.pauseReason(albumID: "a") == .thermalState(.critical) }
        XCTAssertEqual(posts.changedAlbumIDs, [["a"]], "a changed reason is posted")

        harness.postThermalChange()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(posts.changedAlbumIDs, [["a"]], "the same reason again is not")

        harness.scheduler.forgetAlbum(albumID: "a")
        XCTAssertEqual(posts.changedAlbumIDs, [["a"], ["a"]], "the pause ending is posted")
    }

    // MARK: - The stored list

    @MainActor
    func testOrderIsSavedThroughTheStoreAndLoadedByTheNextScheduler() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduler-requests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = RequestedUpgradesStore(directory: directory)
        let harness = SchedulerHarness(requestedUpgradesStore: store)
        harness.runner.holdPass(ofAlbumID: "a")

        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        XCTAssertEqual(harness.requestPassStart("c"), .queued)

        XCTAssertEqual(store.loadAlbumIDs(), harness.scheduler.state.order)
        XCTAssertEqual(store.loadAlbumIDs(), ["a", "b", "c"])
        let relaunched = ICloudDriveUpgradeScheduler(lifecycleNotificationCenter: NotificationCenter(),
                                                     requestedUpgradesStore: store)
        XCTAssertEqual(relaunched.state.order, ["a", "b", "c"], "the stored list is the order of a scheduler created over it")
        XCTAssertEqual(relaunched.state.albums, [:])

        harness.scheduler.forgetAlbum(albumID: "b")
        XCTAssertEqual(store.loadAlbumIDs(), ["a", "c"])
        harness.scheduler.requestStop(albumID: "c")
        XCTAssertEqual(store.loadAlbumIDs(), ["a", "c"], "a stopped album is still requested")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testEraseDeletesTheStoredFile() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduler-requests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = RequestedUpgradesStore(directory: directory)
        let harness = SchedulerHarness(requestedUpgradesStore: store)
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        harness.scheduler.emptyStateForErase()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try await harness.waitUntil("the cancelled pass ends") { !harness.scheduler.hasRunningPass }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "the ending pass does not write it again")
    }

    @MainActor
    func testSchedulerWithoutAStoreKeepsItsOrderInMemoryOnly() async throws {
        let harness = makeHarness()
        harness.runner.holdPass(ofAlbumID: "a")
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)

        XCTAssertEqual(harness.scheduler.state.order, ["a", "b"])
        harness.scheduler.requestStop(albumID: "b")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    // MARK: - Continuing requested albums

    /// A harness whose scheduler was created over a stored list, as after a launch.
    @MainActor
    private func makeRelaunchedHarness(requested albumIDs: [String]) throws -> SchedulerHarness {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduler-continue-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = RequestedUpgradesStore(directory: directory)
        try store.saveAlbumIDs(albumIDs)
        return SchedulerHarness(requestedUpgradesStore: store)
    }

    @MainActor
    func testContinueAfterALaunchRunsEachRequestedAlbumInTurnWithoutATap() async throws {
        let harness = try makeRelaunchedHarness(requested: ["a", "b", "c"])
        harness.finishAlbumsWhosePassEnds = true
        harness.runner.holdPass(ofAlbumID: "a")

        harness.scheduler.continueRequestedUpgrades()
        try await harness.waitUntil("the head album's pass runs") { harness.runner.executedAlbumIDs == ["a"] }

        XCTAssertEqual(harness.albumStepsRun, ["a"], "one folder's album step at launch, not three")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("every album ends") { harness.isIdle && harness.scheduler.state.order.isEmpty }

        XCTAssertEqual(harness.albumStepsRun, ["a", "b", "c"])
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["a", "b", "c"], "one at a time, in the order they were asked for")
        XCTAssertEqual(harness.runner.mostPassesRunningAtOnce, 1)
    }

    @MainActor
    func testContinueDoesNothingWhileThePhoneIsLocked() async throws {
        let harness = try makeRelaunchedHarness(requested: ["a"])
        harness.isUnlocked = false

        harness.scheduler.continueRequestedUpgrades()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.albumStepsRun, [])
        XCTAssertEqual(harness.scheduler.state.order, ["a"], "the request is kept")

        harness.isUnlocked = true
        harness.scheduler.continueRequestedUpgrades()
        try await harness.waitUntil("the album continues once unlocked") { harness.runner.executedAlbumIDs == ["a"] }
    }

    @MainActor
    func testReturningToTheForegroundContinuesTheAlbumThatWasStoppedForTheBackground() async throws {
        let harness = try makeRelaunchedHarness(requested: ["a", "b"])
        harness.albumStepResults["b"] = .waitsForConditions
        harness.runner.holdPass(ofAlbumID: "a")
        harness.runner.ends["a"] = .init(outcome: .stopped(.stopRequested, MigrationPassReport()))
        harness.scheduler.continueRequestedUpgrades()
        try await harness.waitUntil("the head album's pass runs") { harness.runner.executedAlbumIDs == ["a"] }

        harness.postDidEnterBackground()
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass stops") { !harness.scheduler.hasRunningPass }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.albumStepsRun, ["a"], "nothing continues in the background")

        harness.runner.holdPass(ofAlbumID: "a")
        harness.postWillEnterForeground()
        try await harness.waitUntil("the same album continues") { harness.runner.executedAlbumIDs == ["a", "a"] }
        XCTAssertEqual(harness.albumStepsRun, ["a", "a"])
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the pass ends") { !harness.scheduler.hasRunningPass }
    }

    @MainActor
    func testAlbumNeverRequestedIsNeverStartedByContinue() async throws {
        let harness = try makeRelaunchedHarness(requested: [])
        XCTAssertEqual(harness.requestPassStart("x", isUserRequest: false), .started)
        try await harness.waitUntil("the one-off ends") { harness.isIdle }

        harness.scheduler.continueRequestedUpgrades()
        harness.postDidEnterBackground()
        harness.postWillEnterForeground()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.albumStepsRun, [])
        XCTAssertEqual(harness.runner.executedAlbumIDs, ["x"])
    }

    @MainActor
    func testSchedulerWithNoAlbumStepToRunLeavesRequestedAlbumsAlone() async throws {
        let harness = try makeRelaunchedHarness(requested: ["a"])
        harness.scheduler.runAlbumStepForRequestedAlbum = nil

        harness.scheduler.continueRequestedUpgrades()

        XCTAssertNil(harness.scheduler.state.continuingAlbumID)
        XCTAssertEqual(harness.requestPassStart("b"), .started, "a start is not kept waiting for an album step that cannot run")
        try await harness.waitUntil("the pass ends") { harness.isIdle }
        XCTAssertEqual(harness.scheduler.state.order, ["a", "b"])
    }

    @MainActor
    func testUnfinishableHeadAlbumDoesNotBlockTheAlbumBehindIt() async throws {
        let harness = try makeRelaunchedHarness(requested: ["a", "b"])
        harness.albumStepResults["a"] = .cannotContinueThisLaunch
        harness.finishAlbumsWhosePassEnds = true

        harness.scheduler.continueRequestedUpgrades()
        try await harness.waitUntil("b runs and finishes") { harness.runner.executedAlbumIDs == ["b"] && harness.isIdle }

        XCTAssertEqual(harness.albumStepsRun, ["a", "b"], "each album is attempted once")
        XCTAssertEqual(harness.scheduler.state.order, ["a"])
        harness.scheduler.continueRequestedUpgrades()
        harness.postDidEnterBackground()
        harness.postWillEnterForeground()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.albumStepsRun, ["a", "b"], "the unfinishable album is not tried again in this launch")
    }

    @MainActor
    func testAlbumWithNothingToContinueLeavesTheStoredList() async throws {
        let harness = try makeRelaunchedHarness(requested: ["a", "b"])
        harness.albumStepResults["a"] = .nothingToContinue
        harness.albumStepResults["b"] = .waitsForConditions

        harness.scheduler.continueRequestedUpgrades()
        try await harness.waitUntil("both album steps ran") { harness.albumStepsRun == ["a", "b"] }
        try await harness.waitUntil("the second step is over") { harness.scheduler.state.continuingAlbumID == nil }

        XCTAssertEqual(harness.scheduler.state.order, ["b"])
        XCTAssertFalse(harness.scheduler.isRequested(albumID: "a"))
    }

    // MARK: - Pausing at the user's request

    @MainActor
    func testUserPauseStopsTheRunningPassAndTheNextRequestedAlbumStarts() async throws {
        let harness = makeHarness()
        harness.scheduler.runAlbumStepForRequestedAlbum = nil
        harness.runner.holdPass(ofAlbumID: "a")
        harness.runner.ends["a"] = .init(outcome: .stopped(.stopRequested, MigrationPassReport()))
        XCTAssertEqual(harness.requestPassStart("a"), .started)
        XCTAssertEqual(harness.requestPassStart("b"), .queued)
        try await harness.waitUntil("the pass runs") { harness.runner.controls["a"] != nil }

        harness.scheduler.pauseUpgradeAtUserRequest(albumID: "a")

        XCTAssertEqual(harness.runner.controls["a"]?.isStopRequested(), true)
        XCTAssertFalse(harness.scheduler.isRequested(albumID: "a"))
        XCTAssertFalse(harness.scheduler.isActive(albumID: "a"), "an album stopping at the user's request reads as waiting for a tap")
        harness.runner.releasePass(ofAlbumID: "a")
        try await harness.waitUntil("the next album runs and ends") { harness.runner.executedAlbumIDs == ["a", "b"] && harness.isIdle }
        XCTAssertEqual(harness.scheduler.state.order, ["b"])
    }
}

// MARK: - Fixtures

/// Stands in for the pass runner: records each pass it is asked to run, holds
/// one until the test releases it or its task is cancelled, and ends it the way
/// the test says.
@MainActor
final class FakeBlobMigrationPassRunner: ICloudDriveBlobMigrationPassRunning {
    typealias PassControl = ICloudDriveBlobMigrationPassRunner.PassControl
    typealias PassEnd = ICloudDriveBlobMigrationPassRunner.PassEnd

    private(set) var executedAlbumIDs: [String] = []
    private(set) var executedFolders: [URL] = []
    private(set) var controls: [String: PassControl] = [:]
    /// The albums whose pass saw its task cancelled.
    private(set) var cancelledAlbumIDs: [String] = []
    private(set) var mostPassesRunningAtOnce = 0
    private var passesRunning = 0
    private var heldAlbumIDs: Set<String> = []
    /// How each album's pass ends; finished with an empty report unless set.
    var ends: [String: PassEnd] = [:]
    /// The albums whose pass reports progress before it ends, as a pass does
    /// when an item verifies.
    var albumIDsMakingProgress: Set<String> = []

    func holdPass(ofAlbumID albumID: String) { heldAlbumIDs.insert(albumID) }
    func releasePass(ofAlbumID albumID: String) { heldAlbumIDs.remove(albumID) }

    func executeMigrationPass(albumID: String, folder: URL, control: PassControl) async -> PassEnd {
        executedAlbumIDs.append(albumID)
        executedFolders.append(folder)
        controls[albumID] = control
        passesRunning += 1
        mostPassesRunningAtOnce = max(mostPassesRunningAtOnce, passesRunning)
        defer { passesRunning -= 1 }
        while heldAlbumIDs.contains(albumID) {
            if Task.isCancelled {
                cancelledAlbumIDs.append(albumID)
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        if albumIDsMakingProgress.contains(albumID) { control.forgetPause() }
        guard let end = ends[albumID] else {
            onPassFinished?(albumID)
            return PassEnd(outcome: .finished(ICloudDriveBlobMigration.MigrationPassReport()))
        }
        return end
    }

    /// Called as a pass ends finished, before it returns, where the album
    /// finish runs in a real pass.
    var onPassFinished: (@MainActor (String) -> Void)?
}

/// A scheduler of its own with a fake pass runner and device state, and one
/// notification center for the app's lifecycle, the device's state and the
/// scheduler's own posts.
@MainActor
final class SchedulerHarness {
    typealias PassEnd = ICloudDriveBlobMigrationPassRunner.PassEnd

    let notificationCenter = NotificationCenter()
    private let requestedUpgradesStore: RequestedUpgradesStore?
    private(set) lazy var scheduler: ICloudDriveUpgradeScheduler = {
        let scheduler = ICloudDriveUpgradeScheduler(lifecycleNotificationCenter: notificationCenter,
                                                    requestedUpgradesStore: requestedUpgradesStore)
        scheduler.isUnlocked = { [weak self] in self?.isUnlocked ?? false }
        scheduler.runAlbumStepForRequestedAlbum = { [weak self] albumID in
            guard let self else { return .waitsForConditions }
            return await self.runAlbumStep(albumID: albumID)
        }
        return scheduler
    }()
    let runner = FakeBlobMigrationPassRunner()
    var isUnlocked = true
    /// The albums the album step was run for, in order.
    private(set) var albumStepsRun: [String] = []
    /// What the album step answers for an album; it starts the album's pass
    /// and answers `.startedPass` unless set.
    var albumStepResults: [String: ICloudDriveUpgradeScheduler.AlbumStepResult] = [:]
    /// Whether an album is forgotten, as a finished one is, when its pass ends
    /// without stopping.
    var finishAlbumsWhosePassEnds = false {
        didSet {
            guard finishAlbumsWhosePassEnds else {
                runner.onPassFinished = nil
                return
            }
            runner.onPassFinished = { [weak self] albumID in
                self?.scheduler.forgetAlbum(albumID: albumID)
            }
        }
    }

    /// Stands in for the album step: starts the album's pass as the step does
    /// once it has prepared the album.
    private func runAlbumStep(albumID: String) async -> ICloudDriveUpgradeScheduler.AlbumStepResult {
        albumStepsRun.append(albumID)
        await Task.yield()
        if let result = albumStepResults[albumID] { return result }
        requestPassStart(albumID)
        return .startedPass
    }

    /// - Parameter requestedUpgradesStore: where the scheduler keeps its order;
    ///   nil keeps it in memory only.
    init(requestedUpgradesStore: RequestedUpgradesStore? = nil) {
        self.requestedUpgradesStore = requestedUpgradesStore
    }
    var isLowPowerModeEnabled = false
    var thermalState = ProcessInfo.ThermalState.nominal
    var isOnUnmeteredNetwork = true
    private(set) var scheduledRetries: [(delay: TimeInterval, retry: @MainActor () -> Void)] = []
    static let accountChange = Notification.Name("SchedulerHarness.accountChange")

    private(set) lazy var observer = ICloudDriveBlobMigration.DeviceResourceStateObserver(
        isLowPowerModeEnabled: { [unowned self] in MainActor.assumeIsolated { self.isLowPowerModeEnabled } },
        thermalState: { [unowned self] in MainActor.assumeIsolated { self.thermalState } },
        notificationCenter: notificationCenter,
        accountChangeNotification: Self.accountChange,
        scheduleRetry: { [unowned self] delay, retry in
            MainActor.assumeIsolated { self.scheduledRetries.append((delay, retry)) }
        })

    var dependencies: ICloudDriveUpgradeScheduler.PassDependencies {
        ICloudDriveUpgradeScheduler.PassDependencies(
            passRunner: runner,
            conditions: .init(isUnlocked: { true }, hasNetwork: { true },
                              isOnUnmeteredNetwork: { [unowned self] in MainActor.assumeIsolated { self.isOnUnmeteredNetwork } },
                              hasICloudDrive: { true }),
            deviceResourceStateObserver: observer)
    }

    func folder(_ albumID: String) -> URL {
        URL(fileURLWithPath: "/folders/\(albumID)", isDirectory: true)
    }

    /// Whether no album is running, waiting or paused.
    var isIdle: Bool { scheduler.state.albums.isEmpty }

    /// Records the album ids of every `stateDidChange` posted on the harness's
    /// notification center from now on.
    func recordStateDidChangePosts() -> StateDidChangePosts {
        StateDidChangePosts(notificationCenter: notificationCenter)
    }

    func postDidEnterBackground() { notificationCenter.post(name: AppLifecycleNotification.didEnterBackground, object: nil) }
    func postWillEnterForeground() { notificationCenter.post(name: AppLifecycleNotification.willEnterForeground, object: nil) }
    func postPowerChange() { notificationCenter.post(name: .NSProcessInfoPowerStateDidChange, object: nil) }
    func postThermalChange() { notificationCenter.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil) }
    func postAccountChange() { notificationCenter.post(name: Self.accountChange, object: nil) }
    func postNetworkChange() { notificationCenter.post(name: NetworkMonitor.pathDidChange, object: nil) }

    /// Ends the album's next pass paused for `reason`.
    func pauseNextPass(ofAlbumID albumID: String, for reason: ICloudDriveBlobMigration.PauseReason,
                       bytesStillNeeded: Int64? = nil, retryAfter: TimeInterval? = nil) {
        runner.ends[albumID] = PassEnd(outcome: .stopped(.paused(reason), ICloudDriveBlobMigration.MigrationPassReport()),
                                       bytesStillNeeded: bytesStillNeeded, retryAfter: retryAfter)
    }

    /// Lets the album's next pass verify an item and finish.
    func letNextPassFinish(ofAlbumID albumID: String) {
        runner.ends[albumID] = nil
        runner.albumIDsMakingProgress.insert(albumID)
    }

    @discardableResult
    func requestPassStart(_ albumID: String, isUserRequest: Bool = true) -> ICloudDriveUpgradeScheduler.PassStartResult {
        scheduler.requestPassStart(albumID: albumID, folder: folder(albumID), dependencies: dependencies,
                                   isUserRequest: isUserRequest)
    }

    func runPassAndAwaitOutcome(_ albumID: String) async -> ICloudDriveBlobMigration.MigrationRunOutcome {
        await scheduler.runPassAndAwaitOutcome(albumID: albumID, folder: folder(albumID), dependencies: dependencies)
    }

    /// Waits until `condition` holds, failing after five seconds.
    func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

/// The `stateDidChange` notifications posted on a notification center while it
/// lives.
@MainActor
final class StateDidChangePosts {
    private(set) var changedAlbumIDs: [[String]] = []
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(forName: ICloudDriveUpgradeScheduler.stateDidChange,
                                                  object: nil, queue: nil) { [weak self] note in
            let albumIDs = note.userInfo?[ICloudDriveUpgradeScheduler.changedAlbumIDsKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.changedAlbumIDs.append(albumIDs) }
        }
    }

    deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }
}
