//
//  OnboardingManager.swift
//  Encamera
//
//  Created by Alexander Freas on 14.07.22.
//

import Foundation


public enum OnboardingState: Codable, Equatable {
    case completed
    case notStarted
    case hasPasswordAndNotOnboarded
    case hasOnboardingAndNoPassword

    func showOnboarding() -> Bool {
        let show: Bool
        switch self {
        case .completed:
            show = false
        case .notStarted:
            show = true
        case .hasPasswordAndNotOnboarded:
            show = true
        case .hasOnboardingAndNoPassword:
            show = true
        }
        return show
    }
}


public enum OnboardingFlowScreen: String, Identifiable {
    case intro
    case setPassword
    case enterPassword
    case confirmPassword
    case biometrics
    case setPinCode
    case confirmPinCode
    /// The iCloud Backup & Sync confirmation. Its raw value is the
    /// `onboardingScreen` marker text.
    case multiDeviceOptIn
    /// Manual key-phrase entry for the "I have my key" path:
    /// paste/type the phrase, validate it against the fingerprints the existing
    /// data needs, and accept it additively.
    case returningUserManualKeyEntry
    /// Guided flip-the-switch recovery: the second "I have my key" path,
    /// for a user who still has their other device but not the key phrase. Waits
    /// for the key to arrive via iCloud Keychain, with a mandatory timeout,
    /// fingerprint verification on arrival, and a manual-entry fallback.
    case returningUserGuidedSync
    /// One-time upgrade of every remaining iCloud Drive album to CloudKit,
    /// presented outside the onboarding navigation stack. The raw values are the
    /// `onboardingScreen` marker text; the screens are hosted by their own flow,
    /// not `handleNavigationFor`.
    case cloudKitUpgradeIntro
    case cloudKitUpgradeProgress
    case cloudKitUpgradeComplete
    /// Save-recovery-key flow offered after the first item lands in a new
    /// album. Hosted by `RecoveryKeyFlowHostingView`, not the onboarding navigation stack.
    case recoveryKeyIntro
    case recoveryKeyPhrase
    // MARK: - Multi-Device Onboarding
    case loginMethod
    case unlockMethod
    case encryptionExplainer
    case defaultStorage
    case premiumExplainer
    case ready
    case welcomeBack
    case needYourKey
    public var id: Self { self }
}

public enum OnboardingManagerError: Error, Equatable {
    public static func == (lhs: OnboardingManagerError, rhs: OnboardingManagerError) -> Bool {
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
        case (.couldNotSerialize, _), (_, .couldNotSerialize),
             (.couldNotDeserialize, _), (_, .couldNotDeserialize),
             (.couldNotGetFromUserDefaults, _), (_, .couldNotGetFromUserDefaults),
             (.incorrectStateForOperation, _), (_, .incorrectStateForOperation),
             (.unknownError, _), (_, .unknownError):
            return false
        }
    }
    
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
    case incorrectStateForOperation
    case unknownError
}

public protocol OnboardingManaging {
    init(keyManager: KeyManager, authManager: AuthManager)
    func saveOnboardingState(_ state: OnboardingState, authenticationConfiguration: AuthenticationConfiguration) async throws
}

public class OnboardingManagerObservable {
    @Published public var onboardingState: OnboardingState = .notStarted {
        didSet {
            shouldShowOnboarding = onboardingState.showOnboarding()
        }
    }

    @Published public var shouldShowOnboarding: Bool = true
    

}

public class OnboardingManager: OnboardingManaging {
    
    private enum Constants {
        static var onboardingStateKey = "onboardingState"
    }
    public var observables: OnboardingManagerObservable
    
    private var keyManager: KeyManager
    private var authManager: AuthManager

    public required init(keyManager: KeyManager, authManager: AuthManager) {
        self.keyManager = keyManager
        self.authManager = authManager
        self.observables = OnboardingManagerObservable()
    }
    
    func clearOnboardingState() {
        UserDefaultUtils.removeObject(forKey: .onboardingState)
    }
    
    public func saveOnboardingState(_ state: OnboardingState, authenticationConfiguration: AuthenticationConfiguration) async throws {

        switch state {
        case .completed:
            try keyManager.setAuthenticationConfiguration(config: authenticationConfiguration)
            // From here on new data can exist, so a cloud wipe still owed by an
            // earlier erase must never run.
            UserDefaultUtils.removeObject(forKey: .pendingCloudDataWipe)

        case .notStarted,
             .hasPasswordAndNotOnboarded,
             .hasOnboardingAndNoPassword:
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaultUtils.set(data, forKey: .onboardingState)
        } catch {
            throw OnboardingManagerError.couldNotSerialize
        }
        
        await MainActor.run {
            observables.onboardingState = state
        }
        

    }
    
    @MainActor
    @discardableResult public func loadOnboardingState() throws -> OnboardingState {
        let state = try getOnboardingStateFromDefaults()

        if state == .hasPasswordAndNotOnboarded {
            Task {
                let configuration = keyManager.getAuthenticationConfiguration() ?? AuthenticationConfiguration(enabledTypes: [.passcode(.password)])
                try await saveOnboardingState(.completed, authenticationConfiguration: configuration)
            }

            return .completed
        }
        observables.onboardingState = state
        return observables.onboardingState
    }
}

private extension OnboardingManager {
    /// An account that never had a passcode. A device that has not switched
    /// biometrics on for it belongs on the lock screen, whose recovery offers
    /// the prompt: onboarding would let whoever holds the device set a new
    /// passcode over the account.
    var isBiometricsOnlyAccount: Bool {
        guard let configuration = keyManager.getAuthenticationConfiguration() else { return false }
        return configuration.isTypeEnabled(.biometrics) && configuration.passcodeType == nil
    }

    @MainActor
    func getOnboardingStateFromDefaults() throws -> OnboardingState {
        let passwordExists = keyManager.passwordExists()
        
        guard let savedState = UserDefaultUtils.data(forKey: .onboardingState) else {
            if passwordExists {
                return .hasPasswordAndNotOnboarded
            }
            
            return .notStarted
        }
        
        do {
            
            let state = try JSONDecoder().decode(OnboardingState.self, from: savedState)
            if case .completed = state, passwordExists == false && authManager.useBiometricsForAuth == false && !isBiometricsOnlyAccount {
                return .hasOnboardingAndNoPassword
            }
            
            return state
        } catch {
            
            throw OnboardingManagerError.couldNotDeserialize
        }
    }
}
