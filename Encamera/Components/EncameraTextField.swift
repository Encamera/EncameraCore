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
            .padding()
            .background(Color.foregroundSecondary)
            .cornerRadius(10.0)
    }
}


struct EncameraTextField: View {
    
    enum FieldType {
        case secure
        case normal
    }
    
    private var placeholder: String
    private var fieldType: FieldType = .normal
    @Binding var text: String
    @FocusState var isFieldFocused
    
    init(_ placeholder: String, type: FieldType = .normal, text: Binding<String>) {
        self.placeholder = placeholder
        self.fieldType = type
        _text = text
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            
            field.focused($isFieldFocused).modifier(EncameraInputTextField())
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
        case .secure:
            SecureField("", text: $text)
        }
    }
}
