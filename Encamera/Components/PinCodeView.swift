import SwiftUI
import Combine
import EncameraCore


struct PinCodeView: View {
    @Binding var pinCode: String
    var pinLength: PasscodeType.PasscodeLength

    @State private var enteredDigitCount: Int = 0
    @FocusState private var isInputFieldFocused: Bool

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<pinLength.rawValue, id: \.self) { index in
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
                // Ensure pinCode doesn't exceed pinLength
                if newValue.count > pinLength.rawValue {
                    pinCode = String(newValue.prefix(pinLength.rawValue))
                }
                enteredDigitCount = pinCode.count
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

struct PinCodeView_Preview: PreviewProvider {


    @State static var pinCode: String = ""


    static var previews: some View {

        PinCodeView(pinCode: $pinCode, pinLength: .four)
        PinCodeView(pinCode: $pinCode, pinLength: .six)
    }
}
