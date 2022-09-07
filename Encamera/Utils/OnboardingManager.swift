//
//  OnboardingManager.swift
//  Encamera
//
//  Created by Alexander Freas on 14.07.22.
//

import Foundation


enum OnboardingState: Codable, Equatable {
    case completed
    case notStarted
    case hasPasswordAndNotOnboarded
    case hasOnboardingAndNoPassword
//
//    static func ==(lhs: OnboardingState, rhs: OnboardingState) -> Bool {
//        switch (lhs, rhs) {
//        case (.notStarted, .notStarted):
//            return true
//        case (.completed(let saved1), .completed(let saved2)):
//            return saved1 == saved2
//        case (.hasPasswordAndNotOnboarded, .hasPasswordAndNotOnboarded):
//            return true
//        case (.hasOnboardingAndNoPassword, .hasOnboardingAndNoPassword):
//            return true
//        default:
//            return false
//        }
//    }
}


enum OnboardingFlowScreen: Int, Identifiable {
    case intro
    case enterExistingPassword
    case setPassword
    case biometrics
    case setupPrivateKey
    case dataStorageSetting
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
    init(keyManager: KeyManager, authManager: AuthManager, settingsManager: SettingsManager)
    func generateOnboardingFlow() -> [OnboardingFlowScreen]
    func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws
}

class OnboardingManagerObservable {
    @Published var onboardingState: OnboardingState = .notStarted {
        didSet {
            let showOnboarding: Bool
            switch onboardingState {
            case .completed:
                showOnboarding = false
            case .notStarted:
                showOnboarding = true
            case .hasPasswordAndNotOnboarded:
                showOnboarding = true
            case .hasOnboardingAndNoPassword:
                showOnboarding = true
            }
            shouldShowOnboarding = showOnboarding
        }
    }
    
    @Published var shouldShowOnboarding: Bool = true

}

class OnboardingManager: OnboardingManaging {
    
    private enum Constants {
        static var onboardingStateKey = "onboardingState"
    }
    var observables: OnboardingManagerObservable
    
    private var keyManager: KeyManager
    private var authManager: AuthManager
    private var settingsManager: SettingsManager
    
    required init(keyManager: KeyManager, authManager: AuthManager, settingsManager: SettingsManager) {
        self.keyManager = keyManager
        self.authManager = authManager
        self.settingsManager = settingsManager
        self.observables = OnboardingManagerObservable()
    }
    
    func clearOnboardingState() {
        UserDefaults.standard.removeObject(forKey: Constants.onboardingStateKey)
    }
    
    func validate(state: OnboardingState, settings: SavedSettings) throws {
        guard case .completed = state else {
            throw OnboardingManagerError.incorrectStateForOperation
        }
        
        do {
            try settingsManager.validate(settings)
        } catch let validationError as SettingsManagerError {
            throw OnboardingManagerError.settingsManagerError(validationError)
        }
        
    }
    
    func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws {
        debugPrint("onboarding state", state)
        switch state {
        case .completed:
            try validate(state: state, settings: settings)
            do {
                try settingsManager.saveSettings(settings)
            } catch let settingsError as SettingsManagerError {
                throw OnboardingManagerError.settingsManagerError(settingsError)
            } catch {
                throw OnboardingManagerError.unknownError
            }
            
        case .notStarted,
             .hasPasswordAndNotOnboarded,
             .hasOnboardingAndNoPassword:
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Constants.onboardingStateKey)
        } catch {
            throw OnboardingManagerError.couldNotSerialize
        }
        
        await MainActor.run {
            observables.onboardingState = state
        }
        

    }
    
    @discardableResult func loadOnboardingState() throws -> OnboardingState {
        observables.onboardingState = try getOnboardingStateFromDefaults()
        return observables.onboardingState
    }
    
    func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        var screens: [OnboardingFlowScreen] = [.intro]
        if keyManager.passwordExists() {
            screens += [.enterExistingPassword]
        } else {
            screens += [.setPassword]
        }
        if authManager.canAuthenticateWithBiometrics {
            screens += [.biometrics]
        }
        screens += [
            .setupPrivateKey,
            .dataStorageSetting,
            .finished
        ]
        
        return screens

    }
    
}

private extension OnboardingManager {
    func getOnboardingStateFromDefaults() throws -> OnboardingState {
        let passwordExists = keyManager.passwordExists()
        
        guard let savedState = UserDefaults.standard.data(forKey: Constants.onboardingStateKey) else {
            if passwordExists {
                return .hasPasswordAndNotOnboarded
            }
            
            return .notStarted
        }
        
        do {
            
            let state = try JSONDecoder().decode(OnboardingState.self, from: savedState)
            if case .completed = state, passwordExists == false {
                return .hasOnboardingAndNoPassword
            }
            
            return state
        } catch {
            
            throw OnboardingManagerError.couldNotDeserialize
        }
    }
}
