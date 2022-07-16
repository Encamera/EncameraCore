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
    private var cancellables = Set<AnyCancellable>()
    override func setUp() {
        keyManager = DemoKeyManager()
        manager = OnboardingManager(keyManager: keyManager, authManager: DemoAuthManager())
        manager.clearOnboardingState()
    }
    
    func testSaveCompletedOnboardingState() async throws {
        
        let state = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: true, password: "q1w2e3"))
        
        try await manager.saveOnboardingState(state)
        let savedState = try manager.getOnboardingState()
        XCTAssertEqual(state, savedState)
        
    }
    
    func testNotSetOnboardingStateThrows() throws {
        XCTAssertThrowsError(try manager.getOnboardingState())
    }
    
    func testPublishedOnSave() async throws {
        let state = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: true, password: "q1w2e3"))
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
        let state = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: true, password: "q1w2e3"))
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
    
    func testOnboardingFlowGeneratesWithExistingPassword() async throws {
        let keyManager = DemoKeyManager()
        keyManager.hasExistingPassword = true
        manager = OnboardingManager(keyManager: keyManager, authManager: DemoAuthManager())
        let flow = manager.generateOnboardingFlow()
        
        XCTAssertEqual(flow, [.intro, .enterExistingPassword, .biometrics, .finished])
    }
    
    
    
    
}
