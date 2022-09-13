//
//  AuthenticationView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.07.22.
//

import SwiftUI

private enum AuthenticationViewError {
    case noPasswordGiven
    case passwordIncorrect
    case biometricsFailed
    case biometricsNotAvailable
    case keychainError(KeyManagerError)
    
}

struct AuthenticationView: View {
    
    class AuthenticationViewModel: ObservableObject {
        private var authManager: AuthManager
        private var keyManager: KeyManager
        @Published var password: String = ""
        @Published fileprivate var displayedError: AuthenticationViewError?
        
        var availableBiometric: AuthenticationMethod? {
            authManager.availableBiometric
        }
        
        init(authManager: AuthManager, keyManager: KeyManager) {
            self.authManager = authManager
            self.keyManager = keyManager
        }
        
        func authenticatePassword() {
            if password.count > 0 {
                do {
                    try authManager.authorize(with: password, using: keyManager)
                
                } catch let keyManagerError as KeyManagerError {
                    if keyManagerError == .notFound {
                        displayedError = .keychainError(keyManagerError)
                    }
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
    
    @StateObject var viewModel: AuthenticationViewModel
    
    var body: some View {
        VStack {
            
            HStack {
                SecureTextField("Password", text: $viewModel.password)
                Button {
                    viewModel.authenticatePassword()
                } label: {
                    Image(systemName: "lock.circle")
                        .resizable()
                        .frame(width: 50.0, height: 50.0)
                        .foregroundColor(.white)
                        
                }

            }
            Spacer()
                .frame(height: 50.0)
            if let biometric = viewModel.availableBiometric {
                Button {
                    viewModel.password = ""
                    viewModel.authenticateWithBiometrics()
                } label: {
                    Image(systemName: biometric.imageNameForMethod)
                        .resizable()
                        .foregroundColor(.white)
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
        .background(Color.black)
        
    }
}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(viewModel: .init(authManager: DemoAuthManager(), keyManager: DemoKeyManager()))
    }
}
