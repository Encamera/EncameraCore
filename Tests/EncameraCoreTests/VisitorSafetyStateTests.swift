//
//  VisitorSafetyStateTests.swift
//  EncameraCoreTests
//
//  Pins the Photos access and key backup values the visitor profile reports,
//  so the backend CHECK constraints and the client never disagree.
//

import XCTest
import Photos
@testable import EncameraCore

final class VisitorSafetyStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaultUtils.removeObject(forKey: .keyBackupMethodsRecorded)
    }

    override func tearDown() {
        UserDefaultUtils.removeObject(forKey: .keyBackupMethodsRecorded)
        super.tearDown()
    }

    // MARK: Photos access

    func testPhotoAccessMapsEveryAuthorizationStatus() {
        XCTAssertEqual(PhotoAccessLevel(.authorized), .full)
        XCTAssertEqual(PhotoAccessLevel(.limited), .limited)
        XCTAssertEqual(PhotoAccessLevel(.denied), .denied)
        XCTAssertEqual(PhotoAccessLevel(.restricted), .restricted)
        XCTAssertEqual(PhotoAccessLevel(.notDetermined), .notAsked)
    }

    func testPhotoAccessRawValuesMatchTheBackendEnum() {
        XCTAssertEqual(
            PhotoAccessLevel.allCases.map(\.rawValue),
            ["full", "limited", "denied", "restricted", "not_asked"]
        )
    }

    // MARK: Key backup state

    func testKeyBackupRawValuesMatchTheBackendEnum() {
        XCTAssertEqual(
            KeyBackupState.allCases.map(\.rawValue),
            ["icloud", "password_manager", "phrase"]
        )
    }

    func testEveryBackupIsReportedTogether() {
        XCTAssertEqual(
            KeyBackupState.resolve(isSyncEnabled: true, recorded: [.phrase, .passwordManager]),
            [.icloud, .passwordManager, .phrase]
        )
    }

    func testICloudSyncAloneReportsICloud() {
        XCTAssertEqual(KeyBackupState.resolve(isSyncEnabled: true, recorded: []), [.icloud])
    }

    func testRecordedActionsAreReportedWithoutICloud() {
        XCTAssertEqual(
            KeyBackupState.resolve(isSyncEnabled: false, recorded: [.phrase, .passwordManager]),
            [.passwordManager, .phrase]
        )
        XCTAssertEqual(KeyBackupState.resolve(isSyncEnabled: false, recorded: [.phrase]), [.phrase])
    }

    func testNoBackupIsAnEmptySet() {
        XCTAssertEqual(KeyBackupState.resolve(isSyncEnabled: false, recorded: []), [])
        XCTAssertEqual(KeyBackupState.reportValue([]), [])
    }

    func testReportValueIsSortedSoEqualSetsMatch() {
        XCTAssertEqual(
            KeyBackupState.reportValue([.phrase, .icloud, .passwordManager]),
            ["icloud", "password_manager", "phrase"]
        )
    }

    // MARK: Record

    func testRecordStartsEmpty() {
        XCTAssertEqual(KeyBackupRecord.recorded(), [])
    }

    func testRecordKeepsEveryMethodNoted() {
        KeyBackupRecord.note(.phrase)
        KeyBackupRecord.note(.passwordManager)
        KeyBackupRecord.note(.phrase)

        XCTAssertEqual(KeyBackupRecord.recorded(), [.phrase, .passwordManager])
        XCTAssertEqual(
            UserDefaultUtils.value(forKey: .keyBackupMethodsRecorded) as? [String],
            ["password_manager", "phrase"]
        )
    }

    func testRecordIgnoresUnknownStoredValues() {
        UserDefaultUtils.set(["phrase", "carrier_pigeon"], forKey: .keyBackupMethodsRecorded)
        XCTAssertEqual(KeyBackupRecord.recorded(), [.phrase])
    }

    func testRecordIsDeviceLocal() {
        XCTAssertFalse(UserDefaultKey.keyBackupMethodsRecorded.shouldSyncToiCloud)
    }
}
