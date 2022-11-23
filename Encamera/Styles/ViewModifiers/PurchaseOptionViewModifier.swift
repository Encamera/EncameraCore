//
//  PurchaseOptionViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI

struct PurchaseOptionViewModifier: ViewModifier {
    
    private static var backgroundColor: Color {
        .foregroundSecondary
    }
    
    private static var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
    
    let isOn: Bool
    
    func body(content: Content) -> some View {
     content.padding()
        
            .frame(maxWidth: .infinity)
            .background(Self.backgroundColor, in: Self.backgroundShape)
            
            .overlay {
                Self.backgroundShape
                    .strokeBorder(
                        Color.accentColor,
                        lineWidth: isOn ? 1 : 0
                    )
            }
    }
}

extension View {
    func productCell(isOn: Bool = false) -> some View {
        self.modifier(PurchaseOptionViewModifier(isOn: isOn))
    }
}
