//
//  AuthManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 06.12.21.
//

import Foundation
import LocalAuthentication

class AuthManager: ObservableObject {
    
    
    @Published var isAuthorized: Bool = false
    

    func deauthorize() {
        isAuthorized = false
    }
    
    func authorize() {
        let context = LAContext()
        var error: NSError?
        guard isAuthorized == false else {
            return
        }
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            isAuthorized = false
            return
        }
        
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Scan face ID to keep your keys secure.") { success, error in
            DispatchQueue.main.async {
                self.isAuthorized = success
            }
        }
    }
}
