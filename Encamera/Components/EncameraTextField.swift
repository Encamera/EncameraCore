//
//  TextField.swift
//  Encamera
//
//  Created by Alexander Freas on 11.07.22.
//

import Foundation
import SwiftUI

private struct EncameraInputTextField: ViewModifier {
    func body(content: Content) -> some View {

        content
            .foregroundColor(.clear)
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


struct EncameraTextField: View {
    
    enum FieldType {
        case secure
        case normal
    }
    
    private var placeholder: String
    private var fieldType: FieldType = .normal
    private var accessibilityIdentifier: String?
    private var contentType: UITextContentType?
    @Binding var text: String
    @FocusState var isFieldFocused
    
    init(_ placeholder: String, type: FieldType = .normal, contentType: UITextContentType? = nil, text: Binding<String>, accessibilityIdentifier: String? = nil) {
        self.placeholder = placeholder
        self.contentType = contentType
        self.fieldType = type
        self.accessibilityIdentifier = accessibilityIdentifier
        _text = text
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            
            field
                .focused($isFieldFocused)
                .modifier(EncameraInputTextField())
            if text.isEmpty {
                Text(placeholder)
                    .fontType(.small)
                                        .onTapGesture {
                        isFieldFocused = true
                    }
                    .padding()
            }
        }
    }
    
    @ViewBuilder private var field: some View {
        
        switch fieldType {
        case .normal:
            TextField("", text: $text)
                .textContentType(contentType)
                .accessibilityIdentifier(self.accessibilityIdentifier ?? "")
        case .secure:
            SecureField("", text: $text)
                .textContentType(contentType)
        }
    }
}
