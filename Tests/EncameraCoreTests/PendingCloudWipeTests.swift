//
//  PendingCloudWipeTests.swift
//  EncameraCoreTests
//
//  The deferred iCloud wipe retries on launch only while it still applies to the
//  data the erase meant to delete: completing onboarding disarms it, because
//  from then on the zone can hold data created after the erase.
//

import XCTest
@testable import EncameraCore

final class PendingCloudWipeTests: XCTestCase {

    private final class CountingCloud: CloudDataErasing, @unchecked Sendable {
        var error: Error?
        private(set) var deleteCount = 0
        func deleteAllCloudData() async throws {
            deleteCount += 1
            if let error { throw error }
        }
        func deleteAllSubscriptions() async throws {}
        func remainingZoneNames() async throws -> [String] { [] }
        func remainingSubscriptionIDs() async throws -> [String] { [] }
        func mayHaveCloudKitData() async -> Bool { true }
    }

    private var savedDefaults: UserDefaultUtils!

    override func setUp() {
        super.setUp()
        savedDefaults = UserDefaultUtils.current
        UserDefaultUtils.current = UserDefaultUtils()
    }

    override func tearDown() {
        UserDefaultUtils.removeObject(forKey: .pendingCloudDataWipe)
        UserDefaultUtils.removeObject(forKey: .onboardingState)
        UserDefaultUtils.current = savedDefaults
        super.tearDown()
    }

    func testRetryRunsWhileOnboardingIsIncompleteAndClearsTheMarkerOnSuccess() async {
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)
        let cloud = CountingCloud()

        let attempted = await EraserUtils.retryPendingCloudWipe(using: cloud)

        XCTAssertTrue(attempted)
        XCTAssertEqual(cloud.deleteCount, 1)
        XCTAssertFalse(UserDefaultUtils.bool(forKey: .pendingCloudDataWipe))
    }

    func testAFailedRetryKeepsTheMarkerForTheNextLaunch() async {
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)
        let cloud = CountingCloud()
        cloud.error = NSError(domain: "test", code: 1)

        await EraserUtils.retryPendingCloudWipe(using: cloud)

        XCTAssertTrue(UserDefaultUtils.bool(forKey: .pendingCloudDataWipe))
    }

    func testNoMarkerMeansNoRetry() async {
        let cloud = CountingCloud()

        let attempted = await EraserUtils.retryPendingCloudWipe(using: cloud)

        XCTAssertFalse(attempted)
        XCTAssertEqual(cloud.deleteCount, 0)
    }

    func testCompletingOnboardingDisarmsTheRetry() async throws {
        UserDefaultUtils.set(true, forKey: .pendingCloudDataWipe)
        let manager = OnboardingManager(keyManager: DemoKeyManager(), authManager: DemoAuthManager())

        try await manager.saveOnboardingState(.completed,
                                              authenticationConfiguration: AuthenticationConfiguration(enabledTypes: [.passcode(.password)]))

        XCTAssertFalse(UserDefaultUtils.bool(forKey: .pendingCloudDataWipe),
                       "after onboarding, the zone can hold new data the old erase never meant to delete")
        let cloud = CountingCloud()
        await EraserUtils.retryPendingCloudWipe(using: cloud)
        XCTAssertEqual(cloud.deleteCount, 0)
    }
}
