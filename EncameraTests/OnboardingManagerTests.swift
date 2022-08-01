//
//  OnboardingManagerTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation
import XCTest
import Combine
@testable import Encamera

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
        
        try await manager.saveOnboardingState(state)
        keyManager.password = "123"
        let savedState = try manager.loadOnboardingState()
        XCTAssertEqual(state, savedState)
        
    }
    
    func testPublishedOnSave() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
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
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        try await manager.saveOnboardingState(state)
        keyManager.password = "123"
        
        manager.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        _ = try manager.loadOnboardingState()
        
        await waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)

    }
    
    func testUserHasStoredPasswordButNoState() async throws {
        keyManager.password = "password"
        let state = try manager.loadOnboardingState()
        
        XCTAssertEqual(state, .hasPasswordAndNotOnboarded)
    }
    
    func testOnboardingFlowGeneratesWithSetPassword() async throws {
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .setPassword, .biometrics, .setupImageKey, .finished])
    }
    
    func testOnboardingFlowCorrectWithKeyManagerError() throws {
        keyManager.throwError = true
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .setPassword, .biometrics, .setupImageKey, .finished])

    }
    
    func testOnboardingFlowWithoutBiometrics() async throws {
        authManager.canAuthenticateWithBiometrics = false
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .setPassword, .setupImageKey, .finished])

    }
    
    func testOnboardingFlowGeneratesWithExistingPassword() async throws {
        let keyManager = DemoKeyManager()
        keyManager.password = "password"
        manager = OnboardingManager(keyManager: keyManager, authManager: DemoAuthManager())
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .enterExistingPassword, .biometrics, .setupImageKey, .finished])
    }
    
    func testOnboardingStateValidationCompletedIncorrectSavedInfo() throws {
        let savedInfo = SavedSettings(useBiometricsForAuth: nil)
        let state = OnboardingState.completed(savedInfo)
        
        
        XCTAssertThrowsError(try manager.validate(state: state), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([ (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")]))))
        }
    }
    
    func testOnboardingStateValidationCompletedNoPassword() throws {
        let savedInfo = SavedSettings(useBiometricsForAuth: nil)
        let state = OnboardingState.completed(savedInfo)
        
        XCTAssertThrowsError(try manager.validate(state: state))
        
        XCTAssertThrowsError(try manager.validate(state: state), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([
                (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")
            ]))))
        }
    }
    
    func testLoadOnboardingStateNotStarted() throws {
        let state = try manager.loadOnboardingState()
        XCTAssertEqual(state, .notStarted)
        XCTAssertEqual(manager.onboardingState, .notStarted)
    }
    
    func testLoadOnboardingStateDeserializationFailed() throws {
        UserDefaults.standard.set(try! JSONEncoder().encode(["hey"]), forKey: "onboardingState")
        XCTAssertThrowsError(try manager.loadOnboardingState(), "load onboarding state") { error in
            guard let error = error as? OnboardingManagerError else {
                XCTFail("unknown error \(error)")
                return
            }
            XCTAssertEqual(error, .couldNotDeserialize)
        }
        XCTAssertEqual(manager.onboardingState, .notStarted)

    }
    
    func testOnboardedButNoPassword() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        
        try await manager.saveOnboardingState(state)
        keyManager.password = nil
        let saved = try manager.loadOnboardingState()
        XCTAssertEqual(saved, .hasOnboardingAndNoPassword)
    }
    
    func testShouldShowOnboardingCompleted() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        keyManager.password = "123"
        try await manager.saveOnboardingState(state)
        try manager.loadOnboardingState()
        XCTAssertFalse(manager.shouldShowOnboarding)
    }
    
    func testShouldShowOnboardingStateNotStarted() throws {
        try manager.loadOnboardingState()
        XCTAssertTrue(manager.shouldShowOnboarding)
    }
    
    func testShouldShowOnboardingStateNoPassword() async throws {
        let state = OnboardingState.completed(SavedSettings(useBiometricsForAuth: true))
        try await manager.saveOnboardingState(state)
        keyManager.password = nil
        try manager.loadOnboardingState()
        XCTAssertTrue(manager.shouldShowOnboarding)
    }
    
    func testShouldShowOnboardingStatePasswordNotOnboarded() async throws {
        try keyManager.setPassword("password")
        try manager.loadOnboardingState()
        XCTAssertTrue(manager.shouldShowOnboarding)

    }
}
