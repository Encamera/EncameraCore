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
    private var cancellables = Set<AnyCancellable>()
    override func setUp() {
        manager = OnboardingManager(keyManager: DemoKeyManager())
        manager.clearOnboardingState()
    }
    
    func testSaveCompletedOnboardingState() throws {
        
        let state = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: true, password: "q1w2e3"))
        
        try manager.saveOnboardingState(state)
        let savedState = try manager.getOnboardingState()
        XCTAssertEqual(state, savedState)
        
    }
    
    func testNotSetOnboardingStateThrows() throws {
        XCTAssertThrowsError(try manager.getOnboardingState())
    }
    
    func testPublishedOnSave() throws {
        let state = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: true, password: "q1w2e3"))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        manager.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        try manager.saveOnboardingState(state)
        waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)
    }
    
    func testPublishedOnGet() throws {
        let state = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: true, password: "q1w2e3"))
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        try manager.saveOnboardingState(state)

        
        manager.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        _ = try manager.getOnboardingState()
        
        waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)

    }
    
}
