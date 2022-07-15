//
//  OnboardingManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 14.07.22.
//

import Foundation

enum OnboardingState: Codable {
    case unknown
    case completed(OnboardingSavedInfo)
    case notStarted
}

struct OnboardingSavedInfo: Codable {
    var useBiometricsForAuth: Bool
    var password: String
}

enum OnboardingError: Error {
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
}

class OnboardingManager: ObservableObject {
    
    private enum Constants {
        static var onboardingStateKey = "onboardingState"
    }
    
    @Published var onboardingState: OnboardingState = .unknown
    
    private var keyManager: KeyManager
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }
    
    func saveOnboardingState(_ state: OnboardingState) throws {
        
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Constants.onboardingStateKey)
            onboardingState = state
        } catch {
            throw OnboardingError.couldNotSerialize
        }
        
    }
    
    func getOnboardingState() throws -> OnboardingState {
        guard let savedState = UserDefaults.standard.data(forKey: Constants.onboardingStateKey) else {
            throw OnboardingError.couldNotGetFromUserDefaults
        }
        
        do {
            
            let state = try JSONDecoder().decode(OnboardingState.self, from: savedState)
            onboardingState = state
            return state
        } catch {
            throw OnboardingError.couldNotDeserialize
        }
    }
    
}
