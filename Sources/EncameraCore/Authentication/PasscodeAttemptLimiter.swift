//
//  PasscodeAttemptLimiter.swift
//  EncameraCore
//
//  Rate limiting for every place a passcode is checked. The state lives in a
//  device-only keychain item rather than UserDefaults: defaults are deleted
//  with the app, the password hash is not, so a reinstall would otherwise hand
//  out a fresh set of guesses against the same hash.
//

import Foundation
import Security

/// A moment read off two clocks at once. The monotonic reading includes time
/// asleep and cannot be moved by changing the device's date, but resets on
/// reboot; the wall-clock reading is the fallback once that has happened.
public struct PasscodeAttemptStamp: Codable, Equatable {
    public var wallClock: Date
    public var monotonic: TimeInterval

    public init(wallClock: Date, monotonic: TimeInterval) {
        self.wallClock = wallClock
        self.monotonic = monotonic
    }
}

public protocol PasscodeAttemptClock {
    var now: Date { get }
    /// Seconds since boot, including sleep.
    var monotonic: TimeInterval { get }
}

public struct SystemPasscodeAttemptClock: PasscodeAttemptClock {
    public init() {}

    public var now: Date { Date() }

    /// Darwin's `CLOCK_MONOTONIC` keeps counting while the device sleeps,
    /// unlike `ProcessInfo.systemUptime`.
    public var monotonic: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

public struct PasscodeAttemptPolicy: Equatable {
    /// How long a failure counts towards `failuresPerWindow`.
    public var failureWindow: TimeInterval
    /// Failures inside `failureWindow` that start a lockout.
    public var failuresPerWindow: Int
    /// Failures since the last successful unlock after which every further
    /// failure starts a lockout. Without it, a guesser who pauses for the
    /// window between bursts would never be locked out.
    public var totalFailuresBeforeEveryFailureLocks: Int
    /// Successive lockout lengths; the last one repeats.
    public var lockoutDurations: [TimeInterval]

    public init(failureWindow: TimeInterval,
                failuresPerWindow: Int,
                totalFailuresBeforeEveryFailureLocks: Int,
                lockoutDurations: [TimeInterval]) {
        precondition(!lockoutDurations.isEmpty)
        self.failureWindow = failureWindow
        self.failuresPerWindow = failuresPerWindow
        self.totalFailuresBeforeEveryFailureLocks = totalFailuresBeforeEveryFailureLocks
        self.lockoutDurations = lockoutDurations
    }

    public static let standard = PasscodeAttemptPolicy(
        failureWindow: 10 * 60,
        failuresPerWindow: 4,
        totalFailuresBeforeEveryFailureLocks: 10,
        lockoutDurations: [60 * 60, 4 * 60 * 60, 24 * 60 * 60]
    )

    /// Short lockouts so debug and TestFlight builds can be walked through by hand.
    public static let debug = PasscodeAttemptPolicy(
        failureWindow: 10 * 60,
        failuresPerWindow: 4,
        totalFailuresBeforeEveryFailureLocks: 10,
        lockoutDurations: [30, 60, 120]
    )

    public static var `default`: PasscodeAttemptPolicy {
#if DEBUG
        .debug
#else
        BuildEnvironment.isTestFlight ? .debug : .standard
#endif
    }
}

public struct PasscodeAttemptState: Codable, Equatable {
    public struct Lockout: Codable, Equatable {
        public var startedAt: PasscodeAttemptStamp
        public var duration: TimeInterval
    }

    public var recentFailures: [PasscodeAttemptStamp] = []
    public var totalFailures = 0
    public var lockoutCount = 0
    public var lockout: Lockout?

    public init() {}
}

public protocol PasscodeAttemptStore {
    func load() -> PasscodeAttemptState?
    func save(_ state: PasscodeAttemptState)
    func clear()
}

public final class PasscodeAttemptLimiter {

    private let store: PasscodeAttemptStore
    private let clock: PasscodeAttemptClock
    public let policy: PasscodeAttemptPolicy

    public init(store: PasscodeAttemptStore = KeychainPasscodeAttemptStore(),
                clock: PasscodeAttemptClock = SystemPasscodeAttemptClock(),
                policy: PasscodeAttemptPolicy = .default) {
        self.store = store
        self.clock = clock
        self.policy = policy
    }

    /// Read from the store on every call, so the lock screen and onboarding
    /// share one count however many limiters exist.
    private var state: PasscodeAttemptState {
        store.load() ?? PasscodeAttemptState()
    }

    /// Time left on the current lockout, or nil when passcode entry is open.
    public var remainingLockout: TimeInterval? {
        remaining(of: state.lockout)
    }

    public var isLockedOut: Bool {
        remainingLockout != nil
    }

    /// Lockouts since the last successful unlock.
    public var lockoutCount: Int {
        state.lockoutCount
    }

    /// The erase escape hatch is offered from the second lockout on, so a
    /// first run of typos never puts it in front of the user.
    public var offersErase: Bool {
        let current = state
        return remaining(of: current.lockout) != nil && current.lockoutCount >= 2
    }

    /// Records a wrong passcode and returns the lockout it started, if any.
    /// A failure reported while already locked out is not counted: nothing
    /// should have been checked.
    @discardableResult
    public func recordFailure() -> TimeInterval? {
        var current = state
        if let remaining = remaining(of: current.lockout) {
            return remaining
        }

        let now = stamp()
        current.totalFailures += 1
        current.recentFailures = current.recentFailures.filter {
            elapsed(since: $0) < policy.failureWindow
        } + [now]

        if current.recentFailures.count >= policy.failuresPerWindow
            || current.totalFailures >= policy.totalFailuresBeforeEveryFailureLocks {
            current.lockoutCount += 1
            let index = min(current.lockoutCount - 1, policy.lockoutDurations.count - 1)
            current.lockout = .init(startedAt: now, duration: policy.lockoutDurations[index])
            current.recentFailures = []
        }

        store.save(current)
        return remaining(of: current.lockout)
    }

    /// A successful unlock, by passcode or biometrics, forgets everything.
    public func recordSuccess() {
        store.clear()
    }

    private func stamp() -> PasscodeAttemptStamp {
        PasscodeAttemptStamp(wallClock: clock.now, monotonic: clock.monotonic)
    }

    private func remaining(of lockout: PasscodeAttemptState.Lockout?) -> TimeInterval? {
        guard let lockout else { return nil }
        let remaining = lockout.duration - elapsed(since: lockout.startedAt)
        return remaining > 0 ? remaining : nil
    }

    /// The monotonic clock only goes backwards across a reboot, so a lower
    /// reading means the wall clock is all that is left. A reboot followed by
    /// enough uptime to pass the old reading is mistaken for the same boot,
    /// which only makes the elapsed time look shorter. A wall clock that has
    /// moved backwards counts as no time passed.
    private func elapsed(since stamp: PasscodeAttemptStamp) -> TimeInterval {
        let monotonic = clock.monotonic
        if monotonic >= stamp.monotonic {
            return monotonic - stamp.monotonic
        }
        return max(0, clock.now.timeIntervalSince(stamp.wallClock))
    }
}

// MARK: - Storage

public final class InMemoryPasscodeAttemptStore: PasscodeAttemptStore {
    public var state: PasscodeAttemptState?

    public init(state: PasscodeAttemptState? = nil) {
        self.state = state
    }

    public func load() -> PasscodeAttemptState? { state }
    public func save(_ state: PasscodeAttemptState) { self.state = state }
    public func clear() { state = nil }
}

/// Never synchronized: one device's failed guesses must not lock another.
/// Readable after first unlock so the lock screen can show a lockout that
/// started before a reboot.
public struct KeychainPasscodeAttemptStore: PasscodeAttemptStore {

    static let service = "com.encamera.passcode-attempts"
    static let account = "state"

    public init() {}

    static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func saveAttributes(value: Data) -> [String: Any] {
        var attributes = baseQuery
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    public func load() -> PasscodeAttemptState? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PasscodeAttemptState.self, from: data)
    }

    public func save(_ state: PasscodeAttemptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        clear()
        SecItemAdd(Self.saveAttributes(value: data) as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(Self.baseQuery as CFDictionary)
    }
}
