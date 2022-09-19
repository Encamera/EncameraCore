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
    @discardableResult func evaluateWithBiometrics() async throws -> Bool
    func waitForAuthResponse() async -> AuthManagerState
}

class DeviceAuthManager: AuthManager {
    
    var context: LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Use Password"
        return context
    }
    
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
    
    @Published private var authState: AuthManagerState = .unauthenticated {
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
    private var generalCancellables = Set<AnyCancellable>()
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

    func waitForAuthResponse() async -> AuthManagerState {
        await waitForAuthResponse(delay: AppConstants.authenticationTimeout)
    }
    
    func waitForAuthResponse(delay: RunLoop.SchedulerTimeType.Stride) async -> AuthManagerState  {
        return await withCheckedContinuation({ continuation in
            if case .authenticated(_) = authState {
                continuation.resume(returning: authState)
            } else {
                Publishers.MergeMany(
                    Just(AuthManagerState.unauthenticated)
                        .delay(for: delay, scheduler: RunLoop.main).eraseToAnyPublisher(),
                    $authState.dropFirst().eraseToAnyPublisher()
                )
                    .first()
                    .sink { value in
                        continuation.resume(returning: value)
                    }
                    .store(in: &generalCancellables)
            }
            
        })
    }
    
    func authorize(with password: String, using keyManager: KeyManager) throws {
        let newState: AuthManagerState
        let check = try keyManager.checkPassword(password)
        if check {
            newState = .authenticated(with: .password)
        } else {
            newState = .unauthenticated
        }
        authState = newState
    }
    
    @discardableResult func evaluateWithBiometrics() async throws -> Bool {
        cancelNotificationObservers()
        
                
        guard let method = availableBiometric else {
            throw AuthManagerError.biometricsNotAvailable
        }
        do {
            print("Attempting LA auth")
            let result = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Keep your encrypted data safe by using \(method.nameForMethod).")
            setupNotificationObservers()
            return result
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
        return false
    }
    
    func authorizeWithBiometrics() async throws {
        guard let method = availableBiometric else {
            throw AuthManagerError.biometricsNotAvailable
        }
        let result = try await evaluateWithBiometrics()
        if result == true {
            self.authState = .authenticated(with: method)
        } else {
            self.authState = .unauthenticated
        }
    }
}

private extension DeviceAuthManager {
    
    func loadAuthenticationPolicy() -> AuthenticationPolicy {
        guard let settings = try? settingsManager.loadSettings() else {
            return AuthenticationPolicy.defaultPolicy
        }
        let preferredAuth: AuthenticationMethod = settings.useBiometricsForAuth ?? false ? availableBiometric ?? .password : .password
        return AuthenticationPolicy(preferredAuthenticationMethod: preferredAuth, authenticationExpirySeconds: 60)
    }
    
    func storeAuthenticationPolicy(_ policy: AuthenticationPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        UserDefaultUtils.set(data, forKey: UserDefaultKey.authenticationPolicy)
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
    }
    
}
