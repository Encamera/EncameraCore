import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {
    @Published var selectedMethods: [AuthenticationMethodType] = []
    @Published var showPinModal = false
    @Published var showPasswordModal = false
    @Published var showFaceIDAlert = false
    @Published var showIncompatibleMethodAlert = false
    @Published var incompatibleMethod: AuthenticationMethodType?
    
    var authManager: AuthManager
    var keyManager: KeyManager
    
    var isFaceIDAvailable: Bool {
        return authManager.availableBiometric != nil
    }
    
    var hasPassword: Bool {
        return keyManager.passwordExists()
    }
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
        
        self.selectedMethods = AuthenticationMethodManager.getAuthenticationMethods()
        
        // If FaceID is available and enabled in the auth manager but not in our methods, add it
        let hasFaceID = authManager.availableBiometric == .faceID && authManager.useBiometricsForAuth
        if hasFaceID && !selectedMethods.contains(.faceID) {
            _ = AuthenticationMethodManager.addAuthenticationMethod(.faceID)
            self.selectedMethods = AuthenticationMethodManager.getAuthenticationMethods()
        }
    }
    
    func toggleMethod(_ method: AuthenticationMethodType) {
        if isMethodSelected(method) {
            // Don't allow removing the last method
            if selectedMethods.count <= 1 {
                return
            }
            
            // Remove the method
            AuthenticationMethodManager.removeAuthenticationMethod(method)
            self.selectedMethods = AuthenticationMethodManager.getAuthenticationMethods()
        } else {
            // Try to add the method
            switch method {
            case .pinCode:
                // Show PIN modal for setup
                showPinModal = true
                
            case .password:
                // Show password modal for setup
                showPasswordModal = true
                
            case .faceID:
                guard isFaceIDAvailable else {
                    return
                }
                
                // If user has a password and is switching to Face ID, show alert
                if hasPassword {
                    showFaceIDAlert = true
                } else {
                    applyFaceIDSelection()
                }
            }
        }
    }
    
    func applyFaceIDSelection() {
        // Add FaceID to the authentication methods
        let success = AuthenticationMethodManager.addAuthenticationMethod(.faceID)
        if !success {
            // Handle incompatible methods
            incompatibleMethod = .faceID
            showIncompatibleMethodAlert = true
            return
        }
        
        self.selectedMethods = AuthenticationMethodManager.getAuthenticationMethods()
    }
    
    func addMethod(_ method: AuthenticationMethodType) {
        let success = AuthenticationMethodManager.addAuthenticationMethod(method)
        if !success {
            // Handle incompatible methods
            incompatibleMethod = method
            showIncompatibleMethodAlert = true
            return
        }
        
        self.selectedMethods = AuthenticationMethodManager.getAuthenticationMethods()
    }
    
    func isMethodSelected(_ method: AuthenticationMethodType) -> Bool {
        return AuthenticationMethodManager.hasAuthenticationMethod(method)
    }
    
    func canSelectMethod(_ method: AuthenticationMethodType) -> Bool {
        switch method {
        case .faceID:
            return isFaceIDAvailable
        case .pinCode, .password:
            return true
        }
    }
}

struct AuthenticationMethodView: View {
    @StateObject private var viewModel: AuthenticationMethodViewModel
    @Environment(\.presentationMode) private var presentationMode
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        _viewModel = StateObject(wrappedValue: AuthenticationMethodViewModel(authManager: authManager, keyManager: keyManager))
    }
    
    private func popLastView() {
        presentationMode.wrappedValue.dismiss()
    }
    
    private func getMethodTitle(_ method: AuthenticationMethodType) -> String {
        return method.rawValue
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.selectLoginMethod)
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                Text("You can select multiple authentication methods")
                    .fontType(.pt12)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                
                VStack(spacing: 16) {
                    ForEach(AuthenticationMethodType.allCases, id: \.self) { method in
                        SecurityLevelOption(
                            title: getMethodTitle(method),
                            securityLevel: method.securityLevel,
                            isSelected: viewModel.isMethodSelected(method)
                        ) {
                            if viewModel.canSelectMethod(method) {
                                viewModel.toggleMethod(method)
                            }
                        }
                        .opacity(viewModel.canSelectMethod(method) ? 1.0 : 0.5)
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .sheet(isPresented: $viewModel.showPinModal) {
            ChangePinModal(viewModel: .init(
                authManager: viewModel.authManager,
                keyManager: viewModel.keyManager
            ))
        }
        .sheet(isPresented: $viewModel.showPasswordModal) {
            SetPasswordView(viewModel: .init(
                authManager: viewModel.authManager,
                keyManager: viewModel.keyManager
            ))
        }
        .alert(
            L10n.FaceIDOnlyAlert.title,
            isPresented: $viewModel.showFaceIDAlert,
            actions: {
                Button(L10n.FaceIDOnlyAlert.cancel, role: .cancel) {
                }
                
                Button(L10n.FaceIDOnlyAlert.continue) {
                    viewModel.applyFaceIDSelection()
                }
            },
            message: {
                Text(L10n.FaceIDOnlyAlert.message)
            }
        )
        .alert(
            "Incompatible Authentication Methods",
            isPresented: $viewModel.showIncompatibleMethodAlert,
            actions: {
                Button("OK", role: .cancel) {
                }
            },
            message: {
                if let method = viewModel.incompatibleMethod {
                    Text("\(method.rawValue) cannot be used with the currently selected methods. PIN and Password cannot be used together.")
                } else {
                    Text("The selected authentication methods are incompatible.")
                }
            }
        )
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewHeader(
                    title: L10n.authenticationMethod,
                    isToolbar: true,
                    textAlignment: .center,
                    titleFont: .pt18
                )
                .frame(maxWidth: .infinity)
            }
        }
        .gradientBackground()
        .screenBlocked()
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView(authManager: DemoAuthManager(), keyManager: DemoKeyManager())
    }
}

