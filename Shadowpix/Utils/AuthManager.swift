//
//  AuthManager.swift
//  Shadowpix
//
//  Created by Alexander Freas on 06.12.21.
//

import Foundation
import LocalAuthentication
import Combine

enum AuthManagerError: Error {
    case passwordIncorrect
    case faceIDFailed
    case faceIDNotAvailable
    case userCancelledFaceID
}

enum AuthenticationMethod: Codable {
    case faceID
    case password
}

enum AuthManagerState: Equatable {
    case authorized(with: AuthenticationMethod)
    case unauthorized
}

struct AuthenticationPolicy: Codable {
    var preferredAuthenticationMethod: AuthenticationMethod
    var authenticationExpirySeconds: Int
}

protocol AuthManager {
    var isAuthorizedPublisher: AnyPublisher<Bool, Never> { get }
    var isAuthorized: Bool { get }
    var canAuthenticateWithBiometrics: Bool { get }
    func deauthorize()
    func checkAuthorizationWithCurrentPolicy() async throws
    func authorize(with password: String, using keyManager: KeyManager) throws
    func authorizeWithFaceID() async throws
}

class DeviceAuthManager: AuthManager {
    
    var isAuthorizedPublisher: AnyPublisher<Bool, Never> {
        isAuthorizedSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    
    private(set) var isAuthorized: Bool = false {
        didSet {
            isAuthorizedSubject.send(isAuthorized)
        }
    }
    
    private var authState: AuthManagerState = .unauthorized {
        didSet {
            guard case .authorized = authState else {
                isAuthorized = false
                return
            }
            isAuthorized = true
        }
    }
    
    var canAuthenticateWithBiometrics: Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        
        return error == nil
    }
    
    private var isAuthorizedSubject: PassthroughSubject<Bool, Never> = .init()
    
    private var policy: AuthenticationPolicy? = AuthenticationPolicy(preferredAuthenticationMethod: .faceID, authenticationExpirySeconds: 60)
    private var lastSuccessfulAuthentication: Date?
    private var cancellables = Set<AnyCancellable>()

    
    init() {
        try! storeAuthenticationPolicy(self.policy!)
        loadAuthenticationPolicy()
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange).sink { _ in
            self.lastSuccessfulAuthentication = nil
        }.store(in: &cancellables)
    }
    

    func deauthorize() {
        authState = .unauthorized
        lastSuccessfulAuthentication = nil
    }
    
    func checkAuthorizationWithCurrentPolicy() async throws {
        
        guard case .unauthorized = authState else {
            return
        }

        
        guard let policy = policy else {
            self.authState = .unauthorized
            return
        }

        switch policy.preferredAuthenticationMethod {
            
        case .faceID:
            try await authorizeWithFaceID()
        case .password:
            reauthorizeForPassword()
        }
        return
    }

    
    func authorize(with password: String, using keyManager: KeyManager) throws {
        let newState: AuthManagerState
        if try keyManager.checkPassword(password) {
            newState = .authorized(with: .password)
        } else {
            newState = .unauthorized
        }
        authState = newState
    }
    
    func authorizeWithFaceID() async throws {
        
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AuthManagerError.faceIDNotAvailable
        }
        context.setCredential("password".data(using: .utf8), type: .applicationPassword)
        do {
            let result = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Scan face ID to keep your keys secure.")
            if result == true {
                self.authState = .authorized(with: .faceID)
            } else {
                self.authState = .unauthorized
            }
        } catch let localAuthError as LAError {
            switch localAuthError.code {
            case .appCancel:
                break
            
            case .authenticationFailed,
                    .invalidContext,
                    .systemCancel,
                    .notInteractive:
                throw AuthManagerError.faceIDFailed
            case .userCancel, .userFallback, .passcodeNotSet:
                throw AuthManagerError.userCancelledFaceID
                
            default:
                throw AuthManagerError.faceIDFailed
            }
        } catch {
            throw AuthManagerError.faceIDFailed
        }
    }
}

private extension DeviceAuthManager {
    
    var policyUserDefaultsKey: String {
        "authenticationPolicy"
    }
    
    private func loadAuthenticationPolicy() {
        guard let data = UserDefaults.standard.data(forKey: policyUserDefaultsKey) else {
            debugPrint("No authentication policy set in UserDefaults")
            policy = nil
            return
        }
        do {
            let policy = try JSONDecoder().decode(AuthenticationPolicy.self, from: data)
            self.policy = policy
        } catch {
            debugPrint("Could not decode authentication policy")
        }
    }
    
    private func storeAuthenticationPolicy(_ policy: AuthenticationPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        UserDefaults.standard.set(data, forKey: policyUserDefaultsKey)
    }
    
    private func reauthorizeForPassword() {
        if let policy = policy, let authTime = lastSuccessfulAuthentication, Date().timeIntervalSinceReferenceDate < authTime.timeIntervalSinceReferenceDate - Double(policy.authenticationExpirySeconds) {
            authState = .authorized(with: .password)
            lastSuccessfulAuthentication = Date()
        } else {
            authState = .unauthorized
            lastSuccessfulAuthentication = nil
        }
    }
    
}
