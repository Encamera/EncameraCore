//
//  ButtonViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 16.11.21.
//

import Foundation
import SwiftUI

struct ButtonViewModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .bold))
            .frame(minHeight: 44)
            .padding(7.0)
            .foregroundColor(.black)
            .background(Color.white)
            .cornerRadius(10)
        
    }
    
}

extension View {
    func primaryButton() -> some View {
        modifier(ButtonViewModifier())
    }
}
