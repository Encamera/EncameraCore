//
//  OnboardingManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 14.07.22.
//

import Foundation


enum OnboardingState: Codable, Equatable {
    case unknown
    case completed(SavedSettings)
    case inProgress(SavedSettings)
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


enum OnboardingFlowScreen: Int, Identifiable {
    case intro
    case enterExistingPassword
    case setPassword
    case biometrics
    case finished
    var id: Self { self }
}

enum OnboardingManagerError: Error, Equatable {
    static func == (lhs: OnboardingManagerError, rhs: OnboardingManagerError) -> Bool {
        switch (lhs, rhs) {
        case (.couldNotSerialize, .couldNotSerialize):
            return true
        case (.couldNotDeserialize, .couldNotDeserialize):
            return true
        case (.couldNotGetFromUserDefaults, .couldNotGetFromUserDefaults):
            return true
        case (.incorrectStateForOperation, .incorrectStateForOperation):
            return true
        case (.unknownError, .unknownError):
            return true
        case (.settingsManagerError(let error1), .settingsManagerError(let error2)):
            return error1 == error2
        default:
            return false            
        }
    }
    
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
    case incorrectStateForOperation
    case settingsManagerError(SettingsManagerError)
    case unknownError
}

protocol OnboardingManaging {
    init(keyManager: KeyManager, authManager: AuthManager)
    func clearOnboardingState()
}

class OnboardingManager: ObservableObject {
    
    private enum Constants {
        static var onboardingStateKey = "onboardingState"
    }
    
    @Published var onboardingState: OnboardingState = .unknown
    
    var shouldShowOnboarding: Bool {
        switch onboardingState {
        case .unknown:
            return true
        case .completed(_):
            return false
        case .inProgress(_):
            return true
        case .notStarted:
            return true
        case .hasPasswordAndNotOnboarded:
            return true
        }
    }
    
    private var keyManager: KeyManager
    private var authManager: AuthManager
    private var settingsManager: SettingsManager
    
    init(keyManager: KeyManager, authManager: AuthManager) {
        self.keyManager = keyManager
        self.authManager = authManager
        self.settingsManager = SettingsManager(authManager: authManager, keyManager: keyManager)
    }
    
    func clearOnboardingState() {
        UserDefaults.standard.removeObject(forKey: Constants.onboardingStateKey)
    }
    
    func validate(state: OnboardingState) throws {
        let settings: SavedSettings
        switch state {
        
        case .completed(let onboardingSavedInfo):
            settings = onboardingSavedInfo
        case .inProgress(let onboardingSavedInfo):
            settings = onboardingSavedInfo
        default:
            throw OnboardingManagerError.incorrectStateForOperation
        }
        do {
            try settingsManager.validate(settings)
        } catch let validationError as SettingsManagerError {
            throw OnboardingManagerError.settingsManagerError(validationError)
        }
        
    }
    
    func saveOnboardingState(_ state: OnboardingState) async throws {
        switch state {
        case .unknown:
            break
        case .completed(let settings):
            try validate(state: state)
            do {
                try await settingsManager.saveSettings(settings)
            } catch let settingsError as SettingsManagerError {
                throw OnboardingManagerError.settingsManagerError(settingsError)
            } catch {
                throw OnboardingManagerError.unknownError
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
        var screens: [OnboardingFlowScreen] = [.intro]
        do {
            
            if try keyManager.passwordExists() {
                screens += [.enterExistingPassword]
            } else {
                screens += [.setPassword]
            }
        } catch {
            screens += [.setPassword]
        }
        if authManager.canAuthenticateWithBiometrics {
            screens += [.biometrics]
        }
        screens += [.finished]
        
        return screens

    }
    
}

