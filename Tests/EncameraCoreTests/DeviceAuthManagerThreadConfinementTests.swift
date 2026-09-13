//
//  DeviceAuthManagerThreadConfinementTests.swift
//  EncameraCoreTests
//

import XCTest
import LocalAuthentication
@testable import EncameraCore

/// `DeviceAuthManager` keeps one cached `LAContext` that both the biometric
/// evaluation path and the did-enter-background handler invalidate. If those two
/// paths run on different threads, invalidating the same context from both at
/// once over-releases it inside `-[LAContext invalidate]` (TestFlight 3.0.0 (1516),
/// EXC_BAD_ACCESS in objc_release). Every touch of the context has to happen on
/// the main thread, where UIKit posts the background notification.
final class DeviceAuthManagerThreadConfinementTests: XCTestCase {

    func testBiometricEvaluationTouchesContextOnMainThreadOnly() async throws {
        let probe = ContextProbe()
        let manager = await MainActor.run { DeviceAuthManager(keyManager: DemoKeyManager(), makeContext: { probe.makeContext() }) }

        try await Task.detached { try await manager.authorizeWithBiometrics() }.value

        let events = probe.events
        XCTAssertFalse(events.isEmpty, "the fake context was never used")
        XCTAssertTrue(events.allSatisfy(\.onMainThread), "context touched off the main thread: \(events)")
    }

    func testBackgroundInvalidationNeverOverlapsBiometricEvaluation() async throws {
        let probe = ContextProbe(invalidateHoldTime: 0.3)
        let manager = await MainActor.run { DeviceAuthManager(keyManager: DemoKeyManager(), makeContext: { probe.makeContext() }) }
        // Populate the cache so the background handler has a context to invalidate.
        await MainActor.run { _ = manager.deviceBiometryType }

        let handlerInsideInvalidate = expectation(description: "background handler entered invalidate()")
        probe.onFirstInvalidateEntry = { handlerInsideInvalidate.fulfill() }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        // Start the unlock attempt only once the handler is inside invalidate()
        // and holding the context, so the two paths are guaranteed to meet.
        try await Task.detached {
            await self.fulfillment(of: [handlerInsideInvalidate], timeout: 2)
            try await manager.authorizeWithBiometrics()
        }.value

        XCTAssertFalse(probe.sawOverlappingInvalidate,
                       "invalidate() was entered from a second thread while another call was still inside it")
    }
}

/// Records every call the manager makes on the contexts it hands out, plus the
/// thread each call arrived on. `invalidateHoldTime` keeps `invalidate()` busy
/// long enough for a second thread to collide with it.
private final class ContextProbe: @unchecked Sendable {
    struct Event: CustomStringConvertible {
        let name: String
        let onMainThread: Bool
        var description: String { "\(name)(main: \(onMainThread))" }
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var invalidateInProgress = false
    private var _sawOverlappingInvalidate = false
    private var firstInvalidateSeen = false
    private let invalidateHoldTime: TimeInterval
    var onFirstInvalidateEntry: (() -> Void)?

    init(invalidateHoldTime: TimeInterval = 0) {
        self.invalidateHoldTime = invalidateHoldTime
    }

    var events: [Event] { lock.withLock { _events } }
    var sawOverlappingInvalidate: Bool { lock.withLock { _sawOverlappingInvalidate } }

    func makeContext() -> LAContext { ProbeContext(probe: self) }

    func record(_ name: String) {
        lock.withLock { _events.append(Event(name: name, onMainThread: Thread.isMainThread)) }
    }

    func beginInvalidate() {
        record("invalidate")
        var entryCallback: (() -> Void)?
        lock.withLock {
            if invalidateInProgress { _sawOverlappingInvalidate = true }
            invalidateInProgress = true
            if !firstInvalidateSeen {
                firstInvalidateSeen = true
                entryCallback = onFirstInvalidateEntry
            }
        }
        entryCallback?()
        if invalidateHoldTime > 0 {
            Thread.sleep(forTimeInterval: invalidateHoldTime)
        }
    }

    func endInvalidate() {
        lock.withLock { invalidateInProgress = false }
    }
}

/// An `LAContext` that reports Face ID as available and succeeds immediately, so
/// the manager's evaluation path runs end to end without a system prompt.
private final class ProbeContext: LAContext {
    private let probe: ContextProbe

    init(probe: ContextProbe) {
        self.probe = probe
        super.init()
    }

    override var biometryType: LABiometryType { .faceID }

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        probe.record("canEvaluatePolicy")
        return true
    }

    override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, (any Error)?) -> Void) {
        probe.record("evaluatePolicy")
        reply(true, nil)
    }

    override func invalidate() {
        probe.beginInvalidate()
        super.invalidate()
        probe.endInvalidate()
    }
}
