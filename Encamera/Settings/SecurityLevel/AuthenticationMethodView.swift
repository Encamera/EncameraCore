import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {
    enum AlertType {
        case disableConfirmation
        case incompatibleMethod
    }
    
    @Published var selectedMethods: [AuthenticationMethodType] = []
    @Published var showPinModal = false
    @Published var showPasswordModal = false
    @Published var incompatibleMethod: AuthenticationMethodType?
    @Published var methodToDisable: AuthenticationMethodType?
    
    // Replace individual alert state with a single alertType
    @Published var activeAlert: AlertType? = nil
    
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
            activeAlert = .disableConfirmation
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
            activeAlert = .incompatibleMethod
            return
        }
        
        self.selectedMethods = authManager.getAuthenticationMethods()
    }
    
    func addMethod(_ method: AuthenticationMethodType) {
        let success = authManager.addAuthenticationMethod(method)
        if !success {
            // Handle incompatible methods
            incompatibleMethod = method
            activeAlert = .incompatibleMethod
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
    
    func isToggleDisabled(_ method: AuthenticationMethodType) -> Bool {
        // If this is the only method selected, disable the toggle
        if isMethodSelected(method) && selectedMethods.count <= 1 {
            return true
        }
        
        // If Face ID is not available, disable that toggle
        if method == .faceID && !isFaceIDAvailable {
            return true
        }
        
        return false
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
        let biometricType = viewModel.authManager.deviceBiometryType
        let useBiometrics = viewModel.authManager.useBiometricsForAuth
        let methodName = method.textDescription
        if useBiometrics && biometricType != nil && method != .faceID {
            return "\(methodName) & \(biometricType!.nameForMethod)"
        } else {
            return methodName
        }
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
                
                VStack(spacing: 16) {
                    ForEach(AuthenticationMethodType.allCases, id: \.self) { method in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(getMethodTitle(method))
                                    .fontType(.pt16, weight: .medium)
                                
                                Text(method.securityLevel)
                                    .fontType(.pt12)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { viewModel.isMethodSelected(method) },
                                set: { newValue in
                                    if newValue != viewModel.isMethodSelected(method) {
                                        viewModel.toggleMethod(method)
                                    }
                                }
                            ))
                            .disabled(viewModel.isToggleDisabled(method))
                            .opacity(viewModel.canSelectMethod(method) ? 1.0 : 0.5)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
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
        .alert(isPresented: Binding<Bool>(
            get: { viewModel.activeAlert != nil },
            set: { if !$0 { viewModel.activeAlert = nil } }
        )) {
            alert(for: viewModel.activeAlert)
        }
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
    
    private func alert(for alertType: AuthenticationMethodViewModel.AlertType?) -> Alert {
        switch alertType {
        case .disableConfirmation:
            return Alert(
                title: Text(L10n.AuthenticationMethod.disableTitle),
                message: {
                    if let method = viewModel.methodToDisable {
                        switch method {
                        case .faceID:
                            return Text(L10n.AuthenticationMethod.confirmDisableFaceID(method.textDescription))
                        case .pinCode:
                            return Text(L10n.AuthenticationMethod.confirmDisablePinCode(method.textDescription.lowercased()))
                        case .password:
                            return Text(L10n.AuthenticationMethod.confirmDisablePassword(method.textDescription.lowercased()))
                        }
                    } else {
                        return Text(L10n.AuthenticationMethod.confirmDisableGeneric)
                    }
                }(),
                primaryButton: .cancel(Text(L10n.AuthenticationMethod.cancel)) {
                    viewModel.methodToDisable = nil
                },
                secondaryButton: .destructive(Text(L10n.AuthenticationMethod.disable)) {
                    if let method = viewModel.methodToDisable {
                        viewModel.disableMethod(method)
                    }
                    viewModel.methodToDisable = nil
                }
            )
        case .incompatibleMethod:
            return Alert(
                title: Text(L10n.AuthenticationMethod.incompatibleTitle),
                message: {
                    if let method = viewModel.incompatibleMethod {
                        return Text(L10n.AuthenticationMethod.incompatibleDetail(method.rawValue))
                    } else {
                        return Text(L10n.AuthenticationMethod.incompatibleMessage)
                    }
                }(),
                dismissButton: .cancel(Text(L10n.AuthenticationMethod.ok))
            )
        case .none:
            return Alert(title: Text(""))
        }
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView(authManager: DemoAuthManager(), keyManager: DemoKeyManager())
    }
}

