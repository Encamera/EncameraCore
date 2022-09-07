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
            .background(Color.white)
            .foregroundColor(.black)
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
