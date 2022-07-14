//
//  TextField.swift
//  Shadowpix
//
//  Created by Alexander Freas on 11.07.22.
//

import Foundation
import SwiftUI

private struct ShadowpixInputTextField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.white)
            .foregroundColor(.black)
            .cornerRadius(10.0)

    }
}

extension TextField {
    func inputTextField() -> some View {
        modifier(ShadowpixInputTextField())
    }
}

extension SecureField {
    func passwordField() -> some View {
        modifier(ShadowpixInputTextField())
    }
}
