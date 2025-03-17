import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {
    @Published var selectedMethods: [AuthenticationMethodType] = []
    @Published var showPinModal = false
    @Published var showPasswordModal = false
    @Published var showIncompatibleMethodAlert = false
    @Published var incompatibleMethod: AuthenticationMethodType?
    @Published var methodToDisable: AuthenticationMethodType?
    @Published var showDisableConfirmation = false
    
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
        
        self.selectedMethods = authManager.getAuthenticationMethods()
        
        // If FaceID is available and enabled in the auth manager but not in our methods, add it
        let hasFaceID = authManager.availableBiometric == .faceID && authManager.useBiometricsForAuth
        if hasFaceID && !selectedMethods.contains(.faceID) {
            _ = authManager.addAuthenticationMethod(.faceID)
            self.selectedMethods = authManager.getAuthenticationMethods()
        }
    }
    
    func toggleMethod(_ method: AuthenticationMethodType) {
        if isMethodSelected(method) {
            // Don't allow removing the last method
            if selectedMethods.count <= 1 {
                return
            }
            
            // Show confirmation before disabling
            methodToDisable = method
            showDisableConfirmation = true
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
                
                applyFaceIDSelection()
            }
        }
    }
    
    func disableMethod(_ method: AuthenticationMethodType) {
        // Remove the method
        authManager.removeAuthenticationMethod(method)
        self.selectedMethods = authManager.getAuthenticationMethods()
    }
    
    func applyFaceIDSelection() {
        // Add FaceID to the authentication methods
        let success = authManager.addAuthenticationMethod(.faceID)
        if !success {
            // Handle incompatible methods
            incompatibleMethod = .faceID
            showIncompatibleMethodAlert = true
            return
        }
        
        self.selectedMethods = authManager.getAuthenticationMethods()
    }
    
    func addMethod(_ method: AuthenticationMethodType) {
        let success = authManager.addAuthenticationMethod(method)
        if !success {
            // Handle incompatible methods
            incompatibleMethod = method
            showIncompatibleMethodAlert = true
            return
        }
        
        self.selectedMethods = authManager.getAuthenticationMethods()
    }
    
    func isMethodSelected(_ method: AuthenticationMethodType) -> Bool {
        return authManager.hasAuthenticationMethod(method)
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
        return method.textDescription
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.selectLoginMethod)
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                Text(L10n.AuthenticationMethod.multipleMethodsInfo)
                    .fontType(.pt12)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                
                // Banner for tap to disable
                if !viewModel.selectedMethods.isEmpty {
                    Text(L10n.AuthenticationMethod.tapToDisableBanner)
                        .fontType(.pt12)
                        .foregroundColor(.gray)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                }
                
                VStack(spacing: 16) {
                    ForEach(AuthenticationMethodType.allCases, id: \.self) { method in
                        SecurityLevelOption(
                            title: getMethodTitle(method),
                            securityLevel: method.securityLevel,
                            isSelected: viewModel.isMethodSelected(method)
                        ) {
                            if viewModel.canSelectMethod(method) {
                                // Only allow toggling if not the last method when trying to disable
                                if viewModel.isMethodSelected(method) && viewModel.selectedMethods.count <= 1 {
                                    // Do nothing - can't disable the last method
                                } else {
                                    viewModel.toggleMethod(method)
                                }
                            }
                        }
                        .opacity(viewModel.canSelectMethod(method) ? 1.0 : 0.5)
                    }
                }
                .padding(.horizontal)
            }
            .screenBlocked()

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
            L10n.AuthenticationMethod.disableTitle,
            isPresented: $viewModel.showDisableConfirmation,
            actions: {
                Button(L10n.AuthenticationMethod.cancel, role: .cancel) {
                    viewModel.methodToDisable = nil
                }
                
                Button(L10n.AuthenticationMethod.disable, role: .destructive) {
                    if let method = viewModel.methodToDisable {
                        viewModel.disableMethod(method)
                    }
                    viewModel.methodToDisable = nil
                }
            },
            message: {
                if let method = viewModel.methodToDisable {
                    Text(L10n.AuthenticationMethod.confirmDisable(method.textDescription))
                } else {
                    Text(L10n.AuthenticationMethod.confirmDisableGeneric)
                }
            }
        )
        .alert(
            L10n.AuthenticationMethod.incompatibleTitle,
            isPresented: $viewModel.showIncompatibleMethodAlert,
            actions: {
                Button(L10n.AuthenticationMethod.ok, role: .cancel) {
                }
            },
            message: {
                if let method = viewModel.incompatibleMethod {
                    Text(L10n.AuthenticationMethod.incompatibleDetail(method.rawValue))
                } else {
                    Text(L10n.AuthenticationMethod.incompatibleMessage)
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
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView(authManager: DemoAuthManager(), keyManager: DemoKeyManager())
    }
}

