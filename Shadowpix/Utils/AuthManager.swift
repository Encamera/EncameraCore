//
//  AuthManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 06.12.21.
//

import Foundation
import LocalAuthentication

struct AuthManager {
    
    private var state: ShadowPixState
    
    init(state: ShadowPixState) {
        self.state = state
    }

    func deauthorize() {
        state.isAuthorized = false
    }
    
    func authorize() {
        let context = LAContext()
        var error: NSError?
        guard state.isAuthorized == false else {
            return
        }
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            state.isAuthorized = false
            return
        }
        
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Scan face ID to keep your keys secure.") { success, error in
            DispatchQueue.main.async {
                state.isAuthorized = success
            }
        }
    }
}
