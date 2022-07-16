//
//  AuthenticationView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.07.22.
//

import SwiftUI

private enum AuthenticationViewError {
    case noPasswordGiven
    case passwordIncorrect
    case faceIDFailed
    case faceIDNotAvailable
    case keychainError(KeyManagerError)
    
}

struct AuthenticationView: View {
    
    class AuthenticationViewModel: ObservableObject {
        private var authManager: AuthManager
        private var keyManager: KeyManager
        @Published var password: String = ""
        @Published fileprivate var displayedError: AuthenticationViewError?
        
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
                    print("Auth manager error", error)
                }
            }
        }
        
        func authenticateWithFaceID() {
            Task {
                do {
                    try await authManager.authorizeWithFaceID()
                } catch let authManagerError as AuthManagerError {
                    await MainActor.run {
                        handleAuthManagerError(authManagerError)
                    }
                } catch {
                    print("Error handling auth", error)
                }
            }
        }
        
        
        func handleAuthManagerError(_ error: AuthManagerError) {
            let displayError: AuthenticationViewError
            switch error {
            case .passwordIncorrect:
                displayError = .passwordIncorrect
            case .faceIDFailed:
                displayError = .faceIDFailed
            case .faceIDNotAvailable:
                displayError = .faceIDNotAvailable
            case .userCancelledFaceID:
                displayError = .faceIDFailed
            }
            displayedError = displayError
        }
    }
    
    @ObservedObject var viewModel: AuthenticationViewModel
    
    var body: some View {
        VStack {
            
            HStack {
                TextField("Password", text: $viewModel.password)
                    .inputTextField()
                Button {
                    
                } label: {
                    Image(systemName: "lock.circle")
                        .resizable()
                        .frame(width: 50.0, height: 50.0)
                        .foregroundColor(.white)
                        
                }

            }
            Spacer().frame(height: 50.0)
            Button {
                viewModel.password = ""
                viewModel.authenticateWithFaceID()
            } label: {
                Image(systemName: "faceid")
                    .resizable()
                    .foregroundColor(.white)
                    .frame(width: 50.0, height: 50.0)
            }.padding()

            Spacer()
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
