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
    case inProgress(OnboardingSavedInfo)
    case notStarted
    case hasPasswordAndNotOnboarded
    
    static func ==(lhs: OnboardingState, rhs: OnboardingState) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown):
            return true
        case (.notStarted, .notStarted):
            return true
        case (.completed(let saved1), .completed(let saved2)):
            return saved1 == saved2
        case (.hasPasswordAndNotOnboarded, .hasPasswordAndNotOnboarded):
            return true
        default:
            return false
        }
        
    }
}

struct OnboardingSavedInfo: Codable, Equatable {
    
    var useBiometricsForAuth: Bool?
    var password: String?
}

enum OnboardingFlowScreen: String, Identifiable {
    case intro
    case enterExistingPassword
    case setPassword
    case biometrics
    case finished
    var id: Self { self }
}

enum OnboardingManagerError: Error {
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
    case errorWithFaceID(Error)
    case keyManagerError(Error)
    case invalidPassword
    case incorrectStateForOperation
}

class OnboardingManager: ObservableObject {
    
    private enum Constants {
        static var onboardingStateKey = "onboardingState"
    }
    
    @Published var onboardingState: OnboardingState = .unknown
    
    private var keyManager: KeyManager
    private var authManager: AuthManager
    private var passwordValidator = PasswordValidator()
    
    init(keyManager: KeyManager, authManager: AuthManager) {
        self.keyManager = keyManager
        self.authManager = authManager
    }
    
    func clearOnboardingState() {
        UserDefaults.standard.removeObject(forKey: Constants.onboardingStateKey)
    }
    
    func validate(state: OnboardingState) throws {
        let onboarding: OnboardingSavedInfo
        switch state {
        
        case .completed(let onboardingSavedInfo):
            onboarding = onboardingSavedInfo
        case .inProgress(let onboardingSavedInfo):
            onboarding = onboardingSavedInfo
        default:
            throw OnboardingManagerError.incorrectStateForOperation
        }
        
        if let password = onboarding.password, passwordValidator.validate(password: password) != .valid {
            throw OnboardingManagerError.invalidPassword
        }
    }
    
    func saveOnboardingState(_ state: OnboardingState) async throws {
        switch state {
        case .unknown:
            break
        case .completed(let onboardingSavedInfo):
            try validate(state: state)
            if onboardingSavedInfo.useBiometricsForAuth ?? false {
                do {
                    try await authManager.authorizeWithFaceID()
                } catch {
                    throw OnboardingManagerError.errorWithFaceID(error)
                }
            }
            do {
                guard let password = onboardingSavedInfo.password else {
                    throw OnboardingManagerError.invalidPassword
                }
                try keyManager.setPassword(password)
            } catch {
                throw OnboardingManagerError.keyManagerError(error)
            }
            
        case .inProgress(_),
                .notStarted,
                .hasPasswordAndNotOnboarded:
            break
        }
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Constants.onboardingStateKey)
        } catch {
            throw OnboardingManagerError.couldNotSerialize
        }
        
        onboardingState = state

    }
    
    func getOnboardingState() throws -> OnboardingState {
        guard let savedState = UserDefaults.standard.data(forKey: Constants.onboardingStateKey) else {
            if try keyManager.passwordExists() {
                return .hasPasswordAndNotOnboarded
            }
            throw OnboardingManagerError.couldNotGetFromUserDefaults
        }
        
        do {
            
            let state = try JSONDecoder().decode(OnboardingState.self, from: savedState)
            onboardingState = state
            return state
        } catch {
            throw OnboardingManagerError.couldNotDeserialize
        }
    }
    
    func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        do {
            var screens: [OnboardingFlowScreen] = [.intro]
            if try keyManager.passwordExists() {
                screens += [.enterExistingPassword]
            } else {
                screens += [.setPassword]
            }
            screens += [.biometrics, .finished]
            
            return screens
        } catch {
            fatalError()
        }
        
    }
    
}
