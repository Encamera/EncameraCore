//
//  BiometricMethodNameTests.swift
//  EncameraCoreTests
//
//  User-facing biometric copy must name the device's actual method, so a
//  Touch ID iPad never reads "Face ID".
//

import XCTest
@testable import EncameraCore

@MainActor
final class BiometricMethodNameTests: XCTestCase {

    func testFaceIDDeviceUsesFaceIDName() {
        let authManager = DemoAuthManager()
        authManager.deviceBiometryType = .faceID
        XCTAssertEqual(authManager.biometricMethodName, L10n.faceID)
    }

    func testTouchIDDeviceUsesTouchIDName() {
        let authManager = DemoAuthManager()
        authManager.deviceBiometryType = .touchID
        XCTAssertEqual(authManager.biometricMethodName, L10n.touchID)
        XCTAssertEqual(
            L10n.BiometricMethod.enable(authManager.biometricMethodName),
            "Turn On Touch ID"
        )
    }

    func testDeviceWithoutBiometryFallsBackToGenericName() {
        let authManager = DemoAuthManager()
        authManager.deviceBiometryType = nil
        XCTAssertEqual(authManager.biometricMethodName, L10n.BiometricMethod.generic)
    }

    func testDisabledOpenSettingsNamesMethodTwice() {
        XCTAssertEqual(
            L10n.BiometricMethod.disabledOpenSettings(L10n.touchID),
            "You have turned off Touch ID for Encamera. Turn it on in Settings to unlock with Touch ID."
        )
    }
}
