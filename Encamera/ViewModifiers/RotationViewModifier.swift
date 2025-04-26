//
//  RotationViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 10.07.22.
//

import Foundation
import SwiftUI
import UIKit

private struct RotationForOrientation: ViewModifier {
    
    @Environment(\.rotationFromOrientation) var rotationFromOrientation
    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func body(content: Content) -> some View {
        if isIPad {
            content
        } else {
            content
                .rotationEffect(Angle(degrees: rotationFromOrientation))
                .animation(.easeOut(duration: 0.2), value: rotationFromOrientation)
        }
    }
}

extension View {
    func rotateForOrientation() -> some View {
        modifier(RotationForOrientation())
    }
}
