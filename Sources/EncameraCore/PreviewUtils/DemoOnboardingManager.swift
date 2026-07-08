import Foundation


public class DemoOnboardingManager: OnboardingManaging {

    required public init(keyManager: KeyManager = DemoKeyManager(), authManager: AuthManager = DemoAuthManager()) {

    }

    public func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        return [.setPinCode]
    }

    public func saveOnboardingState(_ state: OnboardingState, authenticationConfiguration: AuthenticationConfiguration) async throws {
        
    }

}
