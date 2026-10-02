import XCTest
@testable import EncameraCore

private final class FakeClock: PasscodeAttemptClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var monotonic: TimeInterval = 5_000

    func advance(_ seconds: TimeInterval) {
        now += seconds
        monotonic += seconds
    }

    func reboot(wallClockAdvance: TimeInterval) {
        now += wallClockAdvance
        monotonic = 30
    }
}

final class PasscodeAttemptLimiterTests: XCTestCase {

    private var clock: FakeClock!
    private var store: InMemoryPasscodeAttemptStore!
    private let policy = PasscodeAttemptPolicy.standard

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        store = InMemoryPasscodeAttemptStore()
    }

    private func makeLimiter() -> PasscodeAttemptLimiter {
        PasscodeAttemptLimiter(store: store, clock: clock, policy: policy)
    }

    private func fail(_ limiter: PasscodeAttemptLimiter, times: Int) {
        for _ in 0..<times { limiter.recordFailure() }
    }

    /// Waits out any lockout before each failure, so every one is counted.
    private func failCounted(_ limiter: PasscodeAttemptLimiter, times: Int) {
        for _ in 0..<times {
            if let remaining = limiter.remainingLockout { clock.advance(remaining) }
            limiter.recordFailure()
        }
    }

    // MARK: - The window

    func testFourthFailureInsideTheWindowLocksOut() {
        let limiter = makeLimiter()
        fail(limiter, times: 3)
        XCTAssertFalse(limiter.isLockedOut)

        let lockout = limiter.recordFailure()

        XCTAssertEqual(lockout, policy.lockoutDurations[0])
        XCTAssertTrue(limiter.isLockedOut)
        XCTAssertEqual(limiter.lockoutCount, 1)
    }

    func testFailuresOlderThanTheWindowStopCounting() {
        let limiter = makeLimiter()
        fail(limiter, times: 3)
        clock.advance(policy.failureWindow)

        XCTAssertNil(limiter.recordFailure())
        XCTAssertFalse(limiter.isLockedOut)
    }

    func testFailuresSpreadAcrossTheWindowStillLockOut() {
        let limiter = makeLimiter()
        for _ in 0..<3 {
            limiter.recordFailure()
            clock.advance(policy.failureWindow / 4)
        }

        XCTAssertNotNil(limiter.recordFailure())
    }

    // MARK: - Pausing between bursts

    func testGuessingInBurstsUnderTheWindowIsStillCaughtByTheTotal() {
        let limiter = makeLimiter()
        var failures = 0
        while failures < policy.totalFailuresBeforeEveryFailureLocks - 1 {
            limiter.recordFailure()
            failures += 1
            if failures % 3 == 0 { clock.advance(policy.failureWindow) }
        }
        XCTAssertFalse(limiter.isLockedOut)

        XCTAssertNotNil(limiter.recordFailure())
    }

    func testPastTheTotalEveryFailureLocksOut() {
        let limiter = makeLimiter()
        failCounted(limiter, times: policy.totalFailuresBeforeEveryFailureLocks)
        let lockouts = limiter.lockoutCount
        clock.advance(policy.lockoutDurations.max()!)

        XCTAssertNotNil(limiter.recordFailure())
        XCTAssertEqual(limiter.lockoutCount, lockouts + 1)
    }

    // MARK: - Escalation

    func testSuccessiveLockoutsGetLongerAndTheLastLengthRepeats() {
        let limiter = makeLimiter()
        var lengths: [TimeInterval] = []
        for _ in 0..<(policy.lockoutDurations.count + 1) {
            var lockout: TimeInterval?
            while lockout == nil { lockout = limiter.recordFailure() }
            lengths.append(lockout!)
            clock.advance(lockout!)
        }

        XCTAssertEqual(lengths, policy.lockoutDurations + [policy.lockoutDurations.last!])
    }

    func testLockoutEndsAfterItsDuration() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)
        clock.advance(policy.lockoutDurations[0] - 1)
        XCTAssertTrue(limiter.isLockedOut)

        clock.advance(1)
        XCTAssertFalse(limiter.isLockedOut)
    }

    func testFailureDuringALockoutIsNotCounted() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)
        let before = store.state

        limiter.recordFailure()

        XCTAssertEqual(store.state, before)
    }

    // MARK: - Success

    func testSuccessForgetsEverything() {
        let limiter = makeLimiter()
        fail(limiter, times: 9)

        limiter.recordSuccess()

        XCTAssertFalse(limiter.isLockedOut)
        XCTAssertEqual(limiter.lockoutCount, 0)
        XCTAssertNil(store.state)
        fail(limiter, times: 3)
        XCTAssertFalse(limiter.isLockedOut)
    }

    // MARK: - Erase

    func testEraseIsNotOfferedDuringTheFirstLockout() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)

        XCTAssertTrue(limiter.isLockedOut)
        XCTAssertFalse(limiter.offersErase)
    }

    func testEraseIsOfferedDuringTheSecondLockout() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)
        clock.advance(policy.lockoutDurations[0])
        XCTAssertFalse(limiter.offersErase)

        fail(limiter, times: 4)

        XCTAssertTrue(limiter.offersErase)
    }

    /// The old flag was only set when an on-screen timer reached zero, so a
    /// lockout that expired while the app was not running never counted.
    func testFirstLockoutCountsEvenIfItExpiredWhileNoLimiterWasAlive() {
        fail(makeLimiter(), times: 4)
        clock.advance(policy.lockoutDurations[0] * 2)

        let relaunched = makeLimiter()
        fail(relaunched, times: 4)

        XCTAssertTrue(relaunched.offersErase)
    }

    // MARK: - Persistence

    func testStateSurvivesANewLimiter() {
        fail(makeLimiter(), times: 3)

        let relaunched = makeLimiter()

        XCTAssertNotNil(relaunched.recordFailure())
    }

    func testTwoLimitersShareOneCount() {
        let lockScreen = makeLimiter()
        let onboarding = makeLimiter()
        fail(lockScreen, times: 2)
        fail(onboarding, times: 2)

        XCTAssertTrue(lockScreen.isLockedOut)
    }

    // MARK: - Clock tampering

    func testMovingTheWallClockForwardDoesNotEndALockout() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)

        clock.now += policy.lockoutDurations[0] * 10

        XCTAssertTrue(limiter.isLockedOut)
    }

    func testMovingTheWallClockForwardDoesNotAgeFailuresOutOfTheWindow() {
        let limiter = makeLimiter()
        fail(limiter, times: 3)

        clock.now += policy.failureWindow * 10

        XCTAssertNotNil(limiter.recordFailure())
    }

    func testAfterARebootTheWallClockDecides() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)

        clock.reboot(wallClockAdvance: 60)
        XCTAssertEqual(limiter.remainingLockout ?? 0, policy.lockoutDurations[0] - 60, accuracy: 0.001)

        clock.reboot(wallClockAdvance: policy.lockoutDurations[0])
        XCTAssertFalse(limiter.isLockedOut)
    }

    func testAfterARebootAWallClockMovedBackwardsKeepsTheWholeLockout() {
        let limiter = makeLimiter()
        fail(limiter, times: 4)

        clock.reboot(wallClockAdvance: -3600)

        XCTAssertEqual(limiter.remainingLockout ?? 0, policy.lockoutDurations[0], accuracy: 0.001)
    }

    // MARK: - Keychain item

    func testKeychainItemStaysOnThisDevice() {
        let attributes = KeychainPasscodeAttemptStore.saveAttributes(value: Data())

        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testStateRoundTripsThroughJSON() throws {
        let limiter = makeLimiter()
        fail(limiter, times: 4)
        let state = try XCTUnwrap(store.state)

        let decoded = try JSONDecoder().decode(PasscodeAttemptState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
    }
}
