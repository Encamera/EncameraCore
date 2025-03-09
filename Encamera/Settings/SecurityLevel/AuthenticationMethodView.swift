import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {
    @Published var selectedMethod: AuthenticationMethodType
    @Published var showPinModal = false
    @Published var showPasswordModal = false
    
    var authManager: AuthManager
    var keyManager: KeyManager
    
    var isFaceIDAvailable: Bool {
        return authManager.availableBiometric != nil
    }
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
        
        // Initialize with current authentication method from UserDefaults
        let storedMethod = AuthenticationMethodType(rawValue: UserDefaultUtils.string(forKey: .authenticationMethodType) ?? AuthenticationMethodType.pinCode.rawValue) ?? .pinCode
        let hasFaceID = authManager.availableBiometric == .faceID && authManager.useBiometricsForAuth
        
        if hasFaceID && storedMethod == .faceID {
            self.selectedMethod = .faceID
        } else {
            self.selectedMethod = storedMethod
        }
    }
    
    func selectMethod(_ method: AuthenticationMethodType) {
        selectedMethod = method
        
        switch method {
        case .pinCode:
            // Always show PIN modal when selecting PIN, whether setting new or changing from password
            showPinModal = true
            
        case .password:
            showPasswordModal = true
            
        case .faceID:
            guard isFaceIDAvailable else {
                return
            }
            try? keyManager.clearPassword()

        }
        UserDefaultUtils.set(method.rawValue, forKey: .authenticationMethodType)

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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("PLEASE SELECT A METHOD")
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                VStack(spacing: 16) {
                    ForEach(AuthenticationMethodType.allCases, id: \.self) { method in
                        SecurityLevelOption(
                            title: method.rawValue,
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
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewHeader(
                    title: "Authentication method",
                    isToolbar: true,
                    textAlignment: .center,
                    titleFont: .pt18,
                    leftContent: {
                        Button(action: popLastView) {
                            Image(systemName: "chevron.left")
                                .fontType(.pt18, weight: .bold)
                        }
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .navigationBarBackButtonHidden()
        .gradientBackground()
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView(authManager: DemoAuthManager(), keyManager: DemoKeyManager())
    }
}

