//
//  ButtonViewModifier.swift
//  Shadowpix
//
//  Created by Alexander Freas on 16.11.21.
//

import Foundation
import SwiftUI

struct ButtonViewModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content.padding(7.0).foregroundColor(.blue)
            .background(Color.white)
            .cornerRadius(10)
        
    }
    
}

extension Button {
    func buttonStyle() -> some View {
        modifier(ButtonViewModifier())
    }
}
