import SwiftUI

struct PasswordInputView: View {
    private enum Constants {
        static let frameWidth: CGFloat = 250
        static let frameHeight: CGFloat = 50
        static let spacing: CGFloat = 16
        static let cornerRadius: CGFloat = 8
    }
    
    @Binding var password: String
    @FocusState private var isInputFieldFocused: Bool
    var onSubmit: (String) -> Void
    
    var body: some View {
        VStack(spacing: Constants.spacing) {
            EncameraTextField("Enter password",
                            type: .secure,
                            contentType: .password,
                            text: $password,
                            becomeFirstResponder: true)
                
            
            Button("Submit") {
                onSubmit(password)
            }
            .primaryButton()
            .disabled(password.isEmpty)
        }
    }
}

#Preview {
    PasswordInputView(password: .constant(""), onSubmit: { _ in })
        .gradientBackground()
} 
