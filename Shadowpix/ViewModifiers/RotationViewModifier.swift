//
//  RotationViewModifier.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.07.22.
//

import Foundation
import SwiftUI

struct RotationForOrientation: ViewModifier {
    
    @Environment(\.rotationFromOrientation) var rotationFromOrientation
    
    func body(content: Content) -> some View {
        
        content
            .rotationEffect(Angle(degrees: rotationFromOrientation))
            .animation(.easeOut(duration: 0.2), value: rotationFromOrientation)
    }
}

extension View {
    func rotateForOrientation() -> some View {
        modifier(RotationForOrientation())
    }
}
