//
//  AuthManager.swift
//  Encamera
//
//  Created by Alexander Freas on 06.12.21.
//

import Foundation
import LocalAuthentication
import Combine
import UIKit

enum AuthManagerError: Error {
    case passwordIncorrect
    case biometricsFailed
    case biometricsNotAvailable
    case userCancelledBiometrics
}

enum AuthenticationMethod: Codable {
    case touchID
    case faceID
    case password
    
    var nameForMethod: String {
        switch self {
        case .touchID:
            return "Touch ID"
        case .faceID:
            return "Face ID"
        case .password:
            return "Password"
        }
    }
    
    var imageNameForMethod: String {
        switch self {
            
        case .touchID:
            return "touchid"
        case .faceID:
            return "faceid"
        case .password:
            return "rectangle.and.pencil.and.ellipsis"
        }
    }
    
    
    
    
    
    static func methodFrom(biometryType: LABiometryType) -> AuthenticationMethod? {
        switch biometryType {
        case .none:
            return nil
        case .touchID:
            return .touchID
        case .faceID:
            return .faceID
        @unknown default:
            return nil
        }
    }
}

enum AuthManagerState: Equatable {
    case authenticated(with: AuthenticationMethod)
    case unauthenticated
}

struct AuthenticationPolicy: Codable {
    var preferredAuthenticationMethod: AuthenticationMethod
    var authenticationExpirySeconds: Int
    
    static var defaultPolicy: AuthenticationPolicy {
        return AuthenticationPolicy(preferredAuthenticationMethod: .password, authenticationExpirySeconds: 60)
    }
}

protocol AuthManager {
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> { get }
    var isAuthenticated: Bool { get }
    var availableBiometric: AuthenticationMethod? { get }
    var canAuthenticateWithBiometrics: Bool { get }
    func deauthorize()
    func checkAuthorizationWithCurrentPolicy() async throws
    func authorize(with password: String, using keyManager: KeyManager) throws
    func authorizeWithBiometrics() async throws
    
}

class DeviceAuthManager: AuthManager {
    let context = LAContext()
    var _availableBiometric: AuthenticationMethod?
    var availableBiometric: AuthenticationMethod? {
        if let _availableBiometric = _availableBiometric {
            return _availableBiometric
        }
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .none
        }
        _availableBiometric = AuthenticationMethod.methodFrom(biometryType: context.biometryType)
        return _availableBiometric
    }
    
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> {
        isAuthenticatedSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
    
    private(set) var isAuthenticated: Bool = false {
        didSet {
            isAuthenticatedSubject.send(isAuthenticated)
        }
    }
    
    private var authState: AuthManagerState = .unauthenticated {
        didSet {
            guard case .authenticated = authState else {
                isAuthenticated = false
                return
            }
            isAuthenticated = true
        }
    }
    
    var canAuthenticateWithBiometrics: Bool {
        
        return availableBiometric == .faceID || availableBiometric == .touchID
    }
    
    private var isAuthenticatedSubject: PassthroughSubject<Bool, Never> = .init()
    

    private var appStateCancellables = Set<AnyCancellable>()
    private var settingsManager: SettingsManager
    
    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        setupNotificationObservers()
    }
    

    func deauthorize() {
        authState = .unauthenticated
    }
    
    func checkAuthorizationWithCurrentPolicy() async throws {
        
        guard case .unauthenticated = authState else {
            return
        }
        let policy = loadAuthenticationPolicy()
        

        switch policy.preferredAuthenticationMethod {
            
        case .touchID, .faceID:
            try await authorizeWithBiometrics()
        case .password:
            reauthorizeForPassword()
        }
        return
    }

    
    func authorize(with password: String, using keyManager: KeyManager) throws {
        let newState: AuthManagerState
        if try keyManager.checkPassword(password) {
            newState = .authenticated(with: .password)
        } else {
            newState = .unauthenticated
        }
        debugPrint("New auth state", newState)
        authState = newState
    }
    
    func authorizeWithBiometrics() async throws {
        cancelNotificationObservers()
        
                
        guard let method = availableBiometric else {
            throw AuthManagerError.biometricsNotAvailable
        }
        do {
            let result = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Keep your encrypted data safe by using \(method.nameForMethod).")
            if result == true {
                self.authState = .authenticated(with: method)
            } else {
                self.authState = .unauthenticated
            }
            setupNotificationObservers()
        } catch let localAuthError as LAError {
            debugPrint("LAError", localAuthError)
            switch localAuthError.code {
            case .appCancel:
                break
            
            case .authenticationFailed,
                    .invalidContext,
                    .systemCancel,
                    .notInteractive:
                throw AuthManagerError.biometricsFailed
            case .userCancel, .userFallback, .passcodeNotSet:
                throw AuthManagerError.userCancelledBiometrics
                
            default:
                throw AuthManagerError.biometricsFailed
            }
        } catch {
            throw AuthManagerError.biometricsFailed
        }
    }
}

private extension DeviceAuthManager {
    
    var policyUserDefaultsKey: String {
        "authenticationPolicy"
    }
    
    func loadAuthenticationPolicy() -> AuthenticationPolicy {
        guard let settings = try? settingsManager.loadSettings() else {
            return AuthenticationPolicy.defaultPolicy
        }
        let preferredAuth: AuthenticationMethod = settings.useBiometricsForAuth ?? false ? availableBiometric ?? .password : .password
        return AuthenticationPolicy(preferredAuthenticationMethod: preferredAuth, authenticationExpirySeconds: 60)
    }
    
    func storeAuthenticationPolicy(_ policy: AuthenticationPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        UserDefaults.standard.set(data, forKey: policyUserDefaultsKey)
    }
    
    func reauthorizeForPassword() {
        authState = .unauthenticated
    }
    
    func cancelNotificationObservers() {
        appStateCancellables.forEach({$0.cancel()})
    }
    
    func setupNotificationObservers() {
        NotificationUtils.didEnterBackgroundPublisher
            .sink { _ in

                self.deauthorize()
            }.store(in: &appStateCancellables)
        NotificationUtils.didBecomeActivePublisher
            .sink { _ in
                Task {
                    try? await self.checkAuthorizationWithCurrentPolicy()
                }

            }.store(in: &appStateCancellables)

    }
    
}
