//
//  OnboardingManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 14.07.22.
//

import Foundation

enum OnboardingState: Codable, Equatable {
    case unknown
    case completed(OnboardingSavedInfo)
    case notStarted
    
    static func ==(lhs: OnboardingState, rhs: OnboardingState) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return true
        case (.notStarted, .notStarted):
            return true
        case (.completed(let saved1), .completed(let saved2)):
            return saved1 == saved2
        default:
            return false
        }
        
    }
}

struct OnboardingSavedInfo: Codable, Equatable {
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
    
    func clearOnboardingState() {
        UserDefaults.standard.removeObject(forKey: Constants.onboardingStateKey)
    }
    
    func saveOnboardingState(_ state: OnboardingState) throws {
        
        do {
            switch state {
            case .unknown:
                break
            case .completed(let onboardingSavedInfo):
                try keyManager.setPassword(onboardingSavedInfo.password)
            case .notStarted:
                break
            }
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
