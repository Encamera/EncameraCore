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
        
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true, password: "q1w2e3"))
        
        try await manager.saveOnboardingState(state)
        let savedState = try manager.getOnboardingState()
        XCTAssertEqual(state, savedState)
        
    }
    
    func testNotSetOnboardingStateThrows() throws {
        XCTAssertThrowsError(try manager.getOnboardingState())
    }
    
    func testPublishedOnSave() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true, password: "q1w2e3"))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        manager.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        try await manager.saveOnboardingState(state)
        await waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)
    }
    
    func testPublishedOnGet() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true, password: "q1w2e3"))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        try await manager.saveOnboardingState(state)

        
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
        
        XCTAssertThrowsError(try manager.validate(state: state), "unknown state") { error in
            
            XCTAssertEqual(error as! OnboardingManagerError, OnboardingManagerError.incorrectStateForOperation)
        }
    }
    
    func testOnboardingStateValidationCompletedIncorrectSavedInfo() throws {
        let savedInfo = SavedSettings(useBiometricsForAuth: nil, password: nil)
        let state = OnboardingState.completed(savedInfo)
        
        XCTAssertThrowsError(try manager.validate(state: state))
        
        XCTAssertThrowsError(try manager.validate(state: state), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([(SavedSettings.CodingKeys.password, "password must be set"), (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")]))))
        }
    }
}
