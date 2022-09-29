//
//  AuthenticationView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.07.22.
//

import SwiftUI
import Combine

private enum AuthenticationViewError: ErrorDescribable {
    case noPasswordGiven
    case passwordIncorrect
    case biometricsFailed
    case biometricsNotAvailable
    case keychainError(KeyManagerError)
    
    var displayDescription: String {
        switch self {
        case .noPasswordGiven:
            return "Missing password"
        case .passwordIncorrect:
            return "Password incorrect"
        case .biometricsFailed:
            return "Biometrics failed"
        case .biometricsNotAvailable:
            return "Biometrics unavailable"
        case .keychainError(let keyManagerError):
            return keyManagerError.displayDescription
        }
    }
    
}

class AuthenticationViewModel: ObservableObject {
    private var authManager: AuthManager
    var keyManager: KeyManager
    @Published fileprivate var displayedError: AuthenticationViewError?
    var cancellables = Set<AnyCancellable>()
    var availableBiometric: AuthenticationMethod? {
        authManager.availableBiometric
    }
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
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
        let displayError: AuthenticationViewError
        switch error {
        case .passwordIncorrect:
            displayError = .passwordIncorrect
        case .biometricsFailed:
            displayError = .biometricsFailed
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
        VStack {
            PasswordEntry(viewModel: .init(
                keyManager: viewModel.keyManager, stateUpdate: { update in
                    if case .valid(let password) = update {
                        viewModel.authenticatePassword(password: password)
                    }
                }))
            if let error = viewModel.displayedError {
                Text("\(error.displayDescription)")
                    .alertText()
            }
            Spacer()
                .frame(height: 50.0)
            if let biometric = viewModel.availableBiometric {
                Button {
                    viewModel.authenticateWithBiometrics()
                } label: {
                    Image(systemName: biometric.imageNameForMethod)
                        .resizable()
                        .foregroundColor(.foregroundPrimary)
                        .frame(width: 50.0, height: 50.0)
                }.padding()
            }
            Spacer()
        }
        .onAppear {
            if let biometric = viewModel.availableBiometric, biometric == .touchID {
                viewModel.authenticateWithBiometrics()
            }
        }
        .padding()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color.background)
        
    }

}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(viewModel: .init(authManager: DemoAuthManager(), keyManager: DemoKeyManager()))
    }
}
