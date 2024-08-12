//
//  TextField.swift
//  Encamera
//
//  Created by Alexander Freas on 11.07.22.
//

import Foundation
import SwiftUI
import SwiftUIIntrospect

private struct EncameraInputTextField: ViewModifier {
    func body(content: Content) -> some View {

        content
            .foregroundColor(.white)
            .frame(height: 48)
            .background(Color.inputFieldBackgroundColor)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                .inset(by: 0.5)
                .stroke(.white.opacity(0.1), lineWidth: 1)
            )

    }
}

@MainActor
struct EncameraTextField: View {
    
    enum FieldType {
        case secure
        case normal
    }
    
    private var placeholder: String
    private var fieldType: FieldType = .normal
    private var accessibilityIdentifier: String?
    private var contentType: UITextContentType?
    private var onSubmit: (() -> ())?
    @State private var becomeFirstResponder: Bool
    @Binding var text: String
    @FocusState var isFieldFocused
    
    init(_ placeholder: String,
         type: FieldType = .normal,
         contentType: UITextContentType? = nil,
         text: Binding<String>,
         becomeFirstResponder: Bool = false,
         accessibilityIdentifier: String? = nil,
         onSubmit: (() -> ())? = nil
    ) {
        self.becomeFirstResponder = becomeFirstResponder
        self.placeholder = placeholder
        self.contentType = contentType
        self.fieldType = type
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSubmit = onSubmit
        _text = text
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
                field
                    .focused($isFieldFocused)
                    .padding(.leading)
                    .modifier(EncameraInputTextField())


                if text.isEmpty {
                    Text(placeholder)
                        .fontType(.pt18)
                        .padding(.leading)
                        .onTapGesture {
                            isFieldFocused = true
                        }
                }
        }
    }
    
    @ViewBuilder private var field: some View {
        
        switch fieldType {
        case .normal:
            TextField("", text: $text)
                .introspect(.textField, on: .iOS(.v13, .v14, .v15, .v16, .v17)) { (textField: UITextField) in
                    handleIntrospectTextField(textField)
                }
                .onSubmit {
                    onSubmit?()
                }
                .textContentType(contentType)
                .accessibilityIdentifier(self.accessibilityIdentifier ?? "")

        case .secure:
            SecureField("", text: $text)
                .introspect(.textField, on: .iOS(.v13, .v14, .v15, .v16, .v17)) { (textField: UITextField) in
                    handleIntrospectTextField(textField)
                }
                .textContentType(contentType)
        }
    }

    private func handleIntrospectTextField(_ textField: UITextField) {
        if becomeFirstResponder {
            DispatchQueue.global(qos:.background).asyncAfter(deadline: DispatchTime.now() + 0.5) {
                Task { @MainActor in
                    textField.becomeFirstResponder()
                    becomeFirstResponder = false
                }
            }
        }
    }
}

struct EncameraTextField_Previews: PreviewProvider {
    @State static private var text = ""
    @FocusState static private var isFieldFocused: Bool

    static var previews: some View {
        Group {
            EncameraTextField("Placeholder", text: $text)
                .previewLayout(.sizeThatFits)
                .padding()
                .previewDisplayName("Normal Field")
            EncameraTextField("Placeholder", type: .secure, text: $text)
                .previewLayout(.sizeThatFits)
                .padding()
                .previewDisplayName("Secure Field")
        }
    }
}
