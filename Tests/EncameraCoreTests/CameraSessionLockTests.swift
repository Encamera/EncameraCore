// The capture service exists only on iOS.
#if os(iOS)
import XCTest
import AVFoundation
@testable import EncameraCore

/// Stands in for `AVCaptureSession`, which has no camera to run on the simulator.
final class FakeCaptureSession: CaptureSessionRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var starts = 0
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    var isRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }

    func startRunning() {
        lock.withLock {
            running = true
            starts += 1
        }
        onStart?()
    }

    func stopRunning() {
        lock.withLock { running = false }
        onStop?()
    }
}

/// While the app is locked the camera must not run, even though the camera
/// screen stays presented under the lock screen and the app keeps receiving
/// the lifecycle notifications that normally start it.
final class CameraSessionLockTests: XCTestCase {

    private var lifecycle: NotificationCenter!
    private var session: FakeCaptureSession!
    private var service: CameraConfigurationService!

    override func setUp() {
        super.setUp()
        lifecycle = NotificationCenter()
        session = FakeCaptureSession()
        let model = CameraConfigurationServiceModel()
        model.setupResult = .setupComplete
        service = CameraConfigurationService(model: model,
                                             sessionRunner: session,
                                             lifecycleNotificationCenter: lifecycle)
    }

    override func tearDown() {
        service = nil
        session = nil
        lifecycle = nil
        super.tearDown()
    }

    private func waitForStart(_ description: String, after trigger: () -> Void) async {
        let started = expectation(description: description)
        session.onStart = { started.fulfill() }
        trigger()
        await fulfillment(of: [started], timeout: 2)
        session.onStart = nil
    }

    private func waitForStop(_ description: String, after trigger: () -> Void) async {
        let stopped = expectation(description: description)
        session.onStop = { stopped.fulfill() }
        trigger()
        await fulfillment(of: [stopped], timeout: 2)
        session.onStop = nil
    }

    /// Fails if the session starts within the wait.
    private func assertNoStart(_ description: String, after trigger: () -> Void) async {
        let started = expectation(description: description)
        started.isInverted = true
        session.onStart = { started.fulfill() }
        trigger()
        await fulfillment(of: [started], timeout: 0.5)
        session.onStart = nil
    }

    private func leaveTheApp() async {
        await waitForStop("leaving the app stops the session") {
            lifecycle.post(name: AppLifecycleNotification.willResignActive, object: nil)
        }
    }

    func testOpeningTheCameraWhileUnlockedStartsTheSession() async {
        await service.configure()

        XCTAssertTrue(session.isRunning)
    }

    func testOpeningTheCameraWhileLockedDoesNotStartTheSession() async {
        service.setAppLocked(true)

        await service.configure()

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.startCount, 0)
    }

    func testReturningToTheAppWhileLockedDoesNotStartTheSession() async {
        await service.configure()
        await leaveTheApp()
        service.setAppLocked(true)

        await assertNoStart("the session stays off under the lock screen") {
            lifecycle.post(name: AppLifecycleNotification.willEnterForeground, object: nil)
            lifecycle.post(name: AppLifecycleNotification.didBecomeActive, object: nil)
        }

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.startCount, 1, "only the start from opening the camera")
    }

    func testReturningToTheAppWhileUnlockedStartsTheSession() async {
        await service.configure()
        await leaveTheApp()

        await waitForStart("becoming active restarts the session") {
            lifecycle.post(name: AppLifecycleNotification.didBecomeActive, object: nil)
        }

        XCTAssertTrue(session.isRunning)
    }

    func testLockingWhileActiveStopsTheSession() async {
        await service.configure()
        XCTAssertTrue(session.isRunning)

        await waitForStop("locking stops the running session") {
            service.setAppLocked(true)
        }

        XCTAssertFalse(session.isRunning)
    }

    func testUnlockingWithTheCameraStillOpenStartsTheSession() async {
        await service.configure()
        await leaveTheApp()
        service.setAppLocked(true)
        await assertNoStart("the session stays off under the lock screen") {
            lifecycle.post(name: AppLifecycleNotification.didBecomeActive, object: nil)
        }

        await waitForStart("unlocking restarts the camera that is still open") {
            service.setAppLocked(false)
        }

        XCTAssertTrue(session.isRunning)
    }

    func testUnlockingAfterTheCameraClosedDoesNotStartTheSession() async {
        await service.configure()
        await service.stop(observeRestart: false)
        service.setAppLocked(true)

        await assertNoStart("a closed camera stays off after unlocking") {
            service.setAppLocked(false)
        }

        XCTAssertFalse(session.isRunning)
    }
}
#endif
