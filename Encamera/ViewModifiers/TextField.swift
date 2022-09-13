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
            .background(Color.gray)
            .cornerRadius(10.0)

    }
}

extension View {
    func inputTextField() -> some View {
        modifier(EncameraInputTextField())
    }
    
    func noAutoModification() -> some View {
        self.textCase(.lowercase)
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
    }
}

extension SecureField {
    func passwordField() -> some View {
        modifier(EncameraInputTextField())
    }
}


struct SecureTextField: View {
    
    var placeholder: String
    @Binding var text: String
    
    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            
            SecureField("", text: $text).passwordField()
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(.white)
                    .padding()
            }
        }
    }
}

struct InputTextField: View {
    
    var placeholder: String
    @Binding var text: String
    
    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            
            TextField("", text: $text).inputTextField()
            if text.isEmpty {
                Text(placeholder)
                    .foregroundColor(.white)
                    .padding()
            }
        }
    }
}
