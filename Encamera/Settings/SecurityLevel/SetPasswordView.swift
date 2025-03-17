import SwiftUI
import EncameraCore

class SetPasswordViewModel: ObservableObject {
    @Published var password1: String = ""
    @Published var password2: String = ""
    @Published var errorMessage: String?
    @Published var showSuccessAlert = false
    
    private var authManager: AuthManager
    private var keyManager: KeyManager
    var completedAction: (() -> Void)?
    
    init(authManager: AuthManager, keyManager: KeyManager, completedAction: (() -> Void)? = nil) {
        self.authManager = authManager
        self.keyManager = keyManager
        self.completedAction = completedAction
    }
    
    var isPasswordValid: Bool {
        return password1.count >= 6 && password1 == password2
    }
    
    func validateAndSavePassword() {
        guard isPasswordValid else {
            if password1.count < 6 {
                errorMessage = "Password must be at least 6 characters"
            } else {
                errorMessage = "Passwords do not match"
            }
            return
        }
        
        do {
            try keyManager.setOrUpdatePassword(password1)
            authManager.addAuthenticationMethod(.password)
            showSuccessAlert = true
            completedAction?()
        } catch {
            errorMessage = "Failed to save password"
        }
    }
}

struct SetPasswordView: View {
    @StateObject var viewModel: SetPasswordViewModel
    @Environment(\.presentationMode) private var presentationMode
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Set Password")
                .fontType(.pt24, weight: .bold)
            
            Text("Create a strong password to protect your data")
                .fontType(.pt14)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
            
            VStack(spacing: 16) {
                EncameraTextField("Enter password",
                                type: .secure,
                                contentType: .newPassword,
                                text: $viewModel.password1,
                                becomeFirstResponder: true)
                    .padding(.horizontal)
                
                EncameraTextField("Confirm password",
                                type: .secure,
                                contentType: .newPassword,
                                text: $viewModel.password2)
                    .padding(.horizontal)
                
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .fontType(.pt14)
                }
            }

            Button(action: {
                viewModel.validateAndSavePassword()
            }) {
                Text("Save Password")

            }
            .padding(.horizontal)
            .padding(.top, 24)
            .primaryButton()

            Spacer()
        }
        .padding(.top, 48)
        .alert(isPresented: $viewModel.showSuccessAlert) {
            Alert(
                title: Text("Password Set Successfully"),
                message: Text("Your new password has been saved"),
                dismissButton: .default(Text("OK")) {
                    presentationMode.wrappedValue.dismiss()
                    viewModel.completedAction?()
                }
            )
        }
        .overlay(alignment: .topLeading) {
            DismissButton {
                presentationMode.wrappedValue.dismiss()
            }
            .padding(20)
        }
        .gradientBackground()
    }
}

#Preview {
    SetPasswordView(viewModel: .init(authManager: DemoAuthManager(), keyManager: DemoKeyManager()))
} 
