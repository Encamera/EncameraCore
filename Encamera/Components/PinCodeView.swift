import SwiftUI
import Combine


struct PinCodeView: View {
    @Binding var pinCode: String
    var pinLength: Int

    @State private var enteredDigitCount: Int = 0
    @FocusState private var isInputFieldFocused: Bool



    var body: some View {
        VStack {
            // Invisible TextField


            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<pinLength, id: \.self) { index in
                    ZStack {
                        if index == 0 {
                            TextField("", text: $pinCode)
                                .focused($isInputFieldFocused)
                                .frame(maxWidth: 10)
                                .foregroundStyle(Color.clear)
                                .background(Color.clear)
                                .onAppear {
                                    self.isInputFieldFocused = true // Automatically focus to show keyboard
                                }
                                .keyboardType(.numberPad)
                        }
                        CircleView(isFilled: index < enteredDigitCount)
                    }
                }
            }
            .onTapGesture {
                self.isInputFieldFocused = true
            }

            .onChange(of: pinCode) { oldValue, newValue in
                enteredDigitCount = newValue.count
                if enteredDigitCount > pinLength - 1 { // Limit pinCode to 6 digits
                    pinCode = String(newValue.prefix(pinLength))
                }
            }
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

struct PinCodeView_Preview: PreviewProvider {


    @State static var pinCode: String = ""


    static var previews: some View {

        PinCodeView(pinCode: $pinCode, pinLength: 4)
    }
}
