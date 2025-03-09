import SwiftUI

struct PasswordInputView: View {
    @Binding var password: String
    @FocusState private var isInputFieldFocused: Bool
    @State private var showPassword: Bool = false
    var onSubmit: (String) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .trailing) {
                if showPassword {
                    TextField("Enter password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($isInputFieldFocused)
                        .textContentType(.password)
                        .submitLabel(.done)
                } else {
                    SecureField("Enter password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($isInputFieldFocused)
                        .textContentType(.password)
                        .submitLabel(.done)
                }
                
                Button(action: {
                    showPassword.toggle()
                }) {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(.gray)
                }
                .padding(.trailing, 8)
            }
            .frame(width: 250, height: 40)
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
            .cornerRadius(4)
            
            Button("Submit") {
                onSubmit(password)
            }
            .fontType(.pt16, weight: .bold)
            .foregroundColor(.black)
            .frame(width: 250, height: 40)
            .background(!password.isEmpty ? Color.actionYellowGreen : Color.gray)
            .cornerRadius(8)
            .disabled(password.isEmpty)
        }
        .onAppear {
            isInputFieldFocused = true
        }
        .onTapGesture {
            isInputFieldFocused = true
        }
    }
}

#Preview {
    PasswordInputView(password: .constant(""), onSubmit: { _ in })
        .gradientBackground()
} 