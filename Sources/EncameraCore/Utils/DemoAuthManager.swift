//
//  DemoAuthManager.swift
//  Encamera
//
//  Created by Alexander Freas on 16.07.22.
//

import Foundation
import Combine

public class DemoAuthManager: AuthManager {
    
    public func resetAuthenticationMethodsToDefault() {

    }
    
    public func waitForAuthResponse() async -> AuthManagerState {
        return .unauthenticated
    }
    nonisolated public init() {}
    
    public var availableBiometric: AuthenticationMethod? = .faceID

    public var biometricAvailability: BiometricAvailability = .available(.faceID)

    public var isAuthenticatedPublisher: AnyPublisher<Bool, Never> = PassthroughSubject<Bool, Never>().eraseToAnyPublisher()
    
    public var isAuthenticated: Bool = false
    
    public var canAuthenticateWithBiometrics: Bool = true

    public var deviceBiometryType: AuthenticationMethod? = .faceID

    public func deauthorize() {
        
    }

    public func evaluateWithBiometrics() async throws -> Bool {
        return false
    }
    public func authorize(with password: String, using keyManager: KeyManager) throws {
        guard (try? keyManager.checkPassword(password)) == true else {
            throw AuthManagerError.passwordIncorrect
        }
        isAuthenticated = true
    }

    public private(set) var biometricAuthorizationCount = 0
    /// Thrown from `authorizeWithBiometrics` when set.
    public var biometricError: AuthManagerError?
    /// False models an evaluation that returns without throwing and without
    /// unlocking, as a debounced or app-cancelled one does.
    public var biometricUnlocks = true

    public func authorizeWithBiometrics() async throws {
        biometricAuthorizationCount += 1
        if let biometricError { throw biometricError }
        isAuthenticated = biometricUnlocks
    }
    public var useBiometricsForAuth: Bool = true
    


}
