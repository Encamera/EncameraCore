//
//  UnderlineTextField.swift
//  Encamera
//
//  Created by Alexander Freas on 23.01.24.
//

import Foundation
import SwiftUI

// Define a custom ViewModifier
struct UnderlinedModifier: ViewModifier {
    var color: Color = .white // Default color is white
    var thickness: CGFloat = 2 // Default thickness of the underline

    func body(content: Content) -> some View {
        VStack {
            content
            Rectangle()
                .frame(height: thickness)
                .foregroundColor(color)
                .padding(.top, -16) // Adjust the padding as needed

                .padding([.leading, .trailing])
                .opacity(0.1)
        }
    }
}

// Extension to easily apply the modifier
extension View {
    func underlined(color: Color = .white, thickness: CGFloat = 2) -> some View {
        self.modifier(UnderlinedModifier(color: color, thickness: thickness))
    }
}

// Example usage in a SwiftUI view
struct UnderlineTextField: View {
    @Binding var text: String

    var body: some View {
        TextField("", text: $text)
            .padding() // Add padding to make the TextField look better
            .underlined(color: .white, thickness: 2) // Apply the underline
            .background(Color.clear) // Make sure the background is transparent
            .fontType(.pt18, weight: .bold)
            
    }
}

#Preview {

    UnderlineTextField(text: .constant("Test"))
        .padding(20)
}
