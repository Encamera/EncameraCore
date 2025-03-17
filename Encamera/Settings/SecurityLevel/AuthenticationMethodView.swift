import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {
    @Published var selectedMethod: AuthenticationMethodType
    @Published var showPinModal = false
    @Published var showPasswordModal = false
    @Published var showFaceIDAlert = false
    
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
        
        // Initialize with current authentication method from UserDefaults
        let hasFaceID = authManager.availableBiometric == .faceID && authManager.useBiometricsForAuth
        var storedMethod: AuthenticationMethodType? = hasFaceID == true ? .faceID : nil
        storedMethod = AuthenticationMethodManager.getCurrentAuthenticationMethod()

        if hasFaceID && storedMethod == .faceID {
            self.selectedMethod = .faceID
        } else {
            self.selectedMethod = storedMethod
        }
    }
    
    func selectMethod(_ method: AuthenticationMethodType) {
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
    
    func applyFaceIDSelection() {
        try? keyManager.clearPassword()
        // Only update method immediately for FaceID since it doesn't require additional setup
        selectedMethod = .faceID
        AuthenticationMethodManager.setAuthenticationMethod(.faceID)
    }
    
    func updateSelectedMethod(_ method: AuthenticationMethodType) {
        selectedMethod = method
        AuthenticationMethodManager.setAuthenticationMethod(method)
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
        let biometricType = viewModel.authManager.deviceBiometryType
        let useBiometrics = viewModel.authManager.useBiometricsForAuth
        
        if useBiometrics && biometricType != nil && method != .faceID {
            return "\(method.rawValue) & \(biometricType!.nameForMethod)"
        } else {
            return method.rawValue
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
                
                VStack(spacing: 16) {
                    ForEach(AuthenticationMethodType.allCases, id: \.self) { method in
                        SecurityLevelOption(
                            title: getMethodTitle(method),
                            securityLevel: method.securityLevel,
                            isSelected: viewModel.selectedMethod == method
                        ) {
                            if viewModel.canSelectMethod(method) {
                                viewModel.selectMethod(method)
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

