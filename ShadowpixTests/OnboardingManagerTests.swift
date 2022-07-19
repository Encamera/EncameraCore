//
//  OnboardingManagerTests.swift
//  ShadowpixTests
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation
import XCTest
import Combine
@testable import Shadowpix

class OnboardingManagerTests: XCTestCase {
    
    
    private var manager: OnboardingManager!
    private var keyManager: DemoKeyManager!
    private var authManager: DemoAuthManager!
    private var cancellables = Set<AnyCancellable>()
    override func setUp() {
        authManager = DemoAuthManager()
        keyManager = DemoKeyManager()
        manager = OnboardingManager(
            keyManager: keyManager,
            authManager: authManager
        )
        manager.clearOnboardingState()
    }
    
    func testSaveCompletedOnboardingState() async throws {
        
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        
        try await manager.saveOnboardingState(state, password: "q1w2e3")
        let savedState = try manager.getOnboardingState()
        XCTAssertEqual(state, savedState)
        
    }
    
    func testNotSetOnboardingStateThrows() throws {
        XCTAssertThrowsError(try manager.getOnboardingState())
    }
    
    func testPublishedOnSave() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        manager.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        try await manager.saveOnboardingState(state, password: "q1w2e3")
        await waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)
    }
    
    func testPublishedOnGet() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        try await manager.saveOnboardingState(state, password: "q1w2e3")

        
        manager.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        _ = try manager.getOnboardingState()
        
        await waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)

    }
    
    func testUserHasStoredPasswordButNoState() async throws {
        keyManager.hasExistingPassword = true
        let state = try manager.getOnboardingState()
        
        XCTAssertEqual(state, .hasPasswordAndNotOnboarded)
    }
    
    func testOnboardingFlowGeneratesWithSetPassword() async throws {
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .setPassword, .biometrics, .finished])
    }
    
    func testOnboardingFlowCorrectWithKeyManagerError() throws {
        keyManager.throwError = true
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .setPassword, .biometrics, .finished])

    }
    
    func testOnboardingFlowWithoutBiometrics() async throws {
        authManager.canAuthenticateWithBiometrics = false
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .setPassword, .finished])

    }
    
    func testOnboardingFlowGeneratesWithExistingPassword() async throws {
        let keyManager = DemoKeyManager()
        keyManager.hasExistingPassword = true
        manager = OnboardingManager(keyManager: keyManager, authManager: DemoAuthManager())
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .enterExistingPassword, .biometrics, .finished])
    }
    
    func testOnboardingStateValidationUnknown() throws {
        
        let state = OnboardingState.unknown
        
        XCTAssertThrowsError(try manager.validate(state: state, password: nil), "unknown state") { error in
            
            XCTAssertEqual(error as! OnboardingManagerError, OnboardingManagerError.incorrectStateForOperation)
        }
    }
    
    func testOnboardingStateValidationCompletedIncorrectSavedInfo() throws {
        let savedInfo = SavedSettings(useBiometricsForAuth: nil)
        let state = OnboardingState.completed(savedInfo)
        
        
        XCTAssertThrowsError(try manager.validate(state: state, password: ""), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([(SavedSettings.CodingKeys.password, "Password is too short, <4"), (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")]))))
        }
    }
    
    func testOnboardingStateValidationCompletedNoPassword() throws {
        let savedInfo = SavedSettings(useBiometricsForAuth: nil)
        let state = OnboardingState.completed(savedInfo)
        
        XCTAssertThrowsError(try manager.validate(state: state, password: nil))
        
        XCTAssertThrowsError(try manager.validate(state: state, password: nil), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([
                (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")
            ]))))
        }
    }
}
