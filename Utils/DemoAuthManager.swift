//
//  DemoAuthManager.swift
//  Encamera
//
//  Created by Alexander Freas on 16.07.22.
//

import Foundation
import Combine

class DemoAuthManager: AuthManager {
    func waitForAuthResponse() async -> AuthManagerState {
        return .unauthenticated
    }
    
    var availableBiometric: AuthenticationMethod? = .faceID
    
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> = PassthroughSubject<Bool, Never>().eraseToAnyPublisher()
    
    var isAuthenticated: Bool = false
    
    var canAuthenticateWithBiometrics: Bool = true
    
    func deauthorize() {
        
    }
    
    func checkAuthorizationWithCurrentPolicy() async throws {
        
    }
    func evaluateWithBiometrics() async throws -> Bool {
        return false
    }
    func authorize(with password: String, using keyManager: KeyManager) throws {
        
    }
    
    func authorizeWithBiometrics() async throws {
        
    }
    
    
}
