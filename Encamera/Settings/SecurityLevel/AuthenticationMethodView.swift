import SwiftUI
import EncameraCore

enum AuthenticationMethodType: String, CaseIterable {
    case faceID = "Face ID only"
    case pinCode = "PIN Code"
    case password = "Password"
    
    var securityLevel: String {
        switch self {
        case .faceID:
            return "Low protection"
        case .pinCode:
            return "Moderate protection"
        case .password:
            return "Strong protection"
        }
    }
}

class AuthenticationMethodViewModel: ObservableObject {
    @Published var selectedMethod: AuthenticationMethodType
    @Published var showPinModal = false
    @Published var showPasswordModal = false
    
    var authManager: AuthManager
    var keyManager: KeyManager
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
        
        // Initialize with current authentication method from UserDefaults
        let storedMethod = UserDefaultUtils.string(forKey: .authenticationMethodType)
        switch storedMethod {
        case "pinCode":
            self.selectedMethod = .pinCode
        case "password":
            self.selectedMethod = .password
        default:
            self.selectedMethod = .faceID
        }
    }
    
    func selectMethod(_ method: AuthenticationMethodType) {
        selectedMethod = method
        
        switch method {
        case .pinCode:
            if !keyManager.passwordExists() {
                showPinModal = true
            }
            UserDefaultUtils.set(true, forKey: .usesPinPassword)
            UserDefaultUtils.set("pinCode", forKey: .authenticationMethodType)
            
        case .password:
            showPasswordModal = true
            UserDefaultUtils.set(false, forKey: .usesPinPassword)
            UserDefaultUtils.set("password", forKey: .authenticationMethodType)
            
        case .faceID:
            UserDefaultUtils.set("faceID", forKey: .authenticationMethodType)
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
                            viewModel.selectMethod(method)
                        }
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
