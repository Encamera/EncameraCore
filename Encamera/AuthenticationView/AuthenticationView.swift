//
//  AuthenticationView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.07.22.
//

import SwiftUI
import Combine
import EncameraCore

private enum AuthenticationViewError: ErrorDescribable {
    case noPasswordGiven
    case passwordIncorrect
    case biometricsFailed
    case biometricsNotAvailable
    case keychainError(KeyManagerError)
    
    var displayDescription: String {
        switch self {
        case .noPasswordGiven:
            return L10n.missingPassword
        case .passwordIncorrect:
            return L10n.passwordIncorrect
        case .biometricsFailed:
            return L10n.biometricsFailed
        case .biometricsNotAvailable:
            return L10n.biometricsUnavailable
        case .keychainError(let keyManagerError):
            return keyManagerError.displayDescription
        }
    }
    
}

class AuthenticationViewModel: ObservableObject {
    private var authManager: AuthManager
    var keyManager: KeyManager
    @Published fileprivate var displayedError: AuthenticationViewError?
    @Published var enteredPassword: String = ""
    var cancellables = Set<AnyCancellable>()
    var availableBiometric: AuthenticationMethod? {
        if authManager.useBiometricsForAuth {
            return authManager.availableBiometric
        } else {
            return nil
        }
    }
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager

        NotificationUtils.willEnterForegroundPublisher
            .sink { [weak self] _ in
                self?.authenticateWithBiometrics()
            }
            .store(in: &cancellables)
    }
    
    func authenticatePassword(password: String) {
        if password.count > 0 {
            do {
                try authManager.authorize(with: password, using: keyManager)
            
            } catch let keyManagerError as KeyManagerError {
                displayedError = .keychainError(keyManagerError)
            } catch let authManagerError as AuthManagerError {
                handleAuthManagerError(authManagerError)
            } catch {
                debugPrint("Auth manager error", error)
            }
        }
    }
    
    func authenticateWithBiometrics() {
        guard let availableBiometric = availableBiometric else {
            return
        }
        Task {
            do {
                try await authManager.authorizeWithBiometrics()
            } catch let authManagerError as AuthManagerError {
                await MainActor.run {
                    handleAuthManagerError(authManagerError)
                }
            } catch {
                debugPrint("Error handling auth", error)
            }
        }
    }
    
    
    func handleAuthManagerError(_ error: AuthManagerError) {
        let displayError: AuthenticationViewError?
        switch error {
        case .passwordIncorrect:
            displayError = .passwordIncorrect
        case .biometricsFailed:
            displayError = nil
        case .biometricsNotAvailable:
            displayError = .biometricsNotAvailable
        case .userCancelledBiometrics:
            displayError = .biometricsFailed
        }
        displayedError = displayError
    }
}
struct AuthenticationView: View {
    
    
    @StateObject var viewModel: AuthenticationViewModel
    
    var body: some View {
        VStack(spacing: 8) {
            Image("LogoSquare").frame(height: 100)
            Text(L10n.welcomeBack)
                .fontType(.pt20, weight: .bold)
            if let biometric = viewModel.availableBiometric {
                Text("\(L10n.enterPassword) \(L10n.or.lowercased()) \(biometric.nameForMethod)")
            } else {
                Text("\(L10n.enterPassword)")
            }
            Spacer().frame(height: 32)
            if UserDefaultUtils.bool(forKey: .usesPinPassword) {
                PinCodeView(pinCode: $viewModel.enteredPassword, pinLength: AppConstants.pinCodeLength)
            } else {
                PasswordEntry(viewModel: .init(
                    keyManager: viewModel.keyManager, stateUpdate: { update in
                        if case .valid(let password) = update {
                            viewModel.authenticatePassword(password: password)
                        }
                    }))
            }

            if let error = viewModel.displayedError {
                Text("\(error.displayDescription)")
                    .alertText()
            }
            Spacer()
                .frame(height: 28.0)
            if let biometric = viewModel.availableBiometric {
                Text(L10n.or.uppercased())
                    .fontType(.pt14, weight: .bold)
                    .opacity(0.5)
                Spacer().frame(height: 20)
                Button {
                    viewModel.authenticateWithBiometrics()
                } label: {
                    VStack(spacing: 16) {
                        Image(systemName: biometric.imageNameForMethod)
                            .resizable()
                            .frame(width: 50.0, height: 50.0)
                            .opacity(0.5)
                        Text(L10n.unlockWith(biometric.nameForMethod))
                            .fontType(.pt14, weight: .bold)
                    }
                }.padding()
                
            }
            Spacer()
        }
        .onAppear {
            // delay 0.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.authenticateWithBiometrics()
            }
        }
        .padding()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .gradientBackground()
        .ignoresSafeArea(edges: .bottom)
    }

}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(viewModel: .init(authManager: DemoAuthManager(), keyManager: DemoKeyManager()))
            .preferredColorScheme(.dark)
    }
}
