//
//  DemoAuthManager.swift
//  Encamera
//
//  Created by Alexander Freas on 16.07.22.
//

import Foundation
import Combine

class DemoAuthManager: AuthManager {
    var availableBiometric: AuthenticationMethod? = .faceID
    
    var isAuthorizedPublisher: AnyPublisher<Bool, Never> = PassthroughSubject<Bool, Never>().eraseToAnyPublisher()
    
    var isAuthorized: Bool = false
    
    var canAuthenticateWithBiometrics: Bool = true
    
    func deauthorize() {
        
    }
    
    func checkAuthorizationWithCurrentPolicy() async throws {
        
    }
    
    func authorize(with password: String, using keyManager: KeyManager) throws {
        
    }
    
    func authorizeWithBiometrics() async throws {
        
    }
    
    
}
