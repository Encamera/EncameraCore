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
    case authorized(with: AuthenticationMethod)
    case unauthorized
}

struct AuthenticationPolicy: Codable {
    var preferredAuthenticationMethod: AuthenticationMethod
    var authenticationExpirySeconds: Int
    
    static var defaultPolicy: AuthenticationPolicy {
        return AuthenticationPolicy(preferredAuthenticationMethod: .password, authenticationExpirySeconds: 60)
    }
}

protocol AuthManager {
    var isAuthorizedPublisher: AnyPublisher<Bool, Never> { get }
    var isAuthorized: Bool { get }
    var availableBiometric: AuthenticationMethod? { get }
    var canAuthenticateWithBiometrics: Bool { get }
    func deauthorize()
    func checkAuthorizationWithCurrentPolicy() async throws
    func authorize(with password: String, using keyManager: KeyManager) throws
    func authorizeWithBiometrics() async throws
    
}

class DeviceAuthManager: AuthManager {
    
    var availableBiometric: AuthenticationMethod? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .none
        }

        return AuthenticationMethod.methodFrom(biometryType: context.biometryType)
    }
    
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
    
    private var lastSuccessfulAuthentication: Date?
    private var appStateCancellables = Set<AnyCancellable>()
    private var systemClockCancellables: AnyCancellable?
    private var settingsManager: SettingsManager
    
    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        systemClockCancellables = NotificationUtils.systemClockDidChangePublisher.sink { _ in
            self.lastSuccessfulAuthentication = nil
        }
        setupNotificationObservers()
    }
    

    func deauthorize() {
        authState = .unauthorized
        lastSuccessfulAuthentication = nil
    }
    
    func checkAuthorizationWithCurrentPolicy() async throws {
        
        guard case .unauthorized = authState else {
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
            newState = .authorized(with: .password)
        } else {
            newState = .unauthorized
        }
        debugPrint("New auth state", newState)
        authState = newState
    }
    
    func authorizeWithBiometrics() async throws {
        cancelNotificationObservers()
        
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), let method = AuthenticationMethod.methodFrom(biometryType: context.biometryType) else {
            throw AuthManagerError.biometricsNotAvailable
        }
        do {
            let result = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Keep your encrypted data safe by using \(method.nameForMethod).")
            if result == true {
                self.authState = .authorized(with: method)
            } else {
                self.authState = .unauthorized
            }
            setupNotificationObservers()
        } catch let localAuthError as LAError {
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
        let policy = loadAuthenticationPolicy()
        if let authTime = lastSuccessfulAuthentication, Date().timeIntervalSinceReferenceDate < authTime.timeIntervalSinceReferenceDate - Double(policy.authenticationExpirySeconds) {
            authState = .authorized(with: .password)
            lastSuccessfulAuthentication = Date()
        } else {
            authState = .unauthorized
            lastSuccessfulAuthentication = nil
        }
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
