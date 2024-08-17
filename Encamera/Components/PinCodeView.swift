import SwiftUI
import Combine
import EncameraCore

struct PinCodeView: View {
    @Binding var pinCode: String

    @State private var enteredDigitCount: Int = 0
    @State private var errorMessage: String? = nil
    @FocusState private var isInputFieldFocused: Bool
    var pinActionButtonTitle: String
    var savePinAction: ((String) -> Void)?
    var body: some View {
        VStack(alignment: .center) {
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding(.bottom, 10)
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<enteredDigitCount, id: \.self) { index in
                    CircleView(isFilled: index < enteredDigitCount)
                }
            }
            .frame(height: 56)
            .onTapGesture {
                self.isInputFieldFocused = true
            }

            TextField("", text: $pinCode)
                .focused($isInputFieldFocused)
                .keyboardType(.numberPad)
                .foregroundColor(.clear)
                .background(Color.clear)
                .onAppear {
                    self.isInputFieldFocused = true // Automatically focus to show keyboard
                }
                .limitInputLength(to: PasswordValidation.maxPasswordLength) // Limiting input to 8 digits
                .onChange(of: pinCode) { oldValue, newValue in
                    enteredDigitCount = min(newValue.count, PasswordValidation.maxPasswordLength)
                    if enteredDigitCount >= 4 {
                        errorMessage = nil // Clear error when sufficient digits are entered
                    }
                }
                .frame(maxWidth: 1, maxHeight: 1)
                .opacity(0.01) // Hide the actual text field but keep it interactable

                Button(action: savePin) {
                    Text(pinActionButtonTitle)
                        .textButton()
                }
                .padding(.top, 20)
                .opacity(PasswordValidator.validate(password: pinCode) == .valid ? 1 : 0.2)

        }
        .padding()
    }

    private func savePin() {
        if enteredDigitCount < PasswordValidation.minPasswordLength {
            errorMessage = L10n.pinTooShort
        } else {
            errorMessage = nil
            // Proceed with saving the PIN
            savePinAction?(pinCode)
        }
    }
}

struct CircleView: View {
    let isFilled: Bool

    var body: some View {
        Image(systemName: isFilled ? "circle.fill" : "circle")
            .frame(width: 48, height: 56)
            .foregroundColor(isFilled ? .white : .gray) // Change color based on filled state
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
            .cornerRadius(4)
    }
}

// Use the same extension to limit TextField input length as before
extension View {
    func limitInputLength(to maxLength: Int) -> some View {
        self.modifier(LimitInputLengthModifier(maxLength: maxLength))
    }
}

struct LimitInputLengthModifier: ViewModifier {
    let maxLength: Int

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { obj in
                if let textField = obj.object as? UITextField, let text = textField.text, text.count > maxLength {
                    textField.text = String(text.prefix(maxLength))
                }
            }
    }
}

//struct PinCodeView_Preview: PreviewProvider {
//    @State static var pinCode: String = ""
//
//    static var previews: some View {
//        PinCodeView(pinCode: $pinCode)
//    }
//}
