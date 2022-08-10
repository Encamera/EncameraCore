//
//  Text.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import Foundation
import SwiftUI

struct TextViewModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content
    }
}

extension Text {
    
    func titleText() -> some View {
        return self.modifier(TextViewModifier())
    }
    
    func alertText() -> some View {
        return self.lineLimit(3)
            .padding(10)
            .foregroundColor(.white)
            .background(Color.red)
            .cornerRadius(10)
    }
}
