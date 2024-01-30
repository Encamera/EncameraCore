//
//  Spacing.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.24.
//

import Foundation
import SwiftUI

enum Spacing: CGFloat {

    private static var base: CGFloat = 8.0
    private static var multiplier: CGFloat = 1.0

    case pt8 = 1.0
    case pt16 = 2.0
    case pt24 = 3.0
    case pt32 = 4.0
    case pt40 = 5.0
    case pt48 = 6.0
    case pt56 = 7.0
    case pt64 = 8.0

    var value: CGFloat {
        return Spacing.base * Spacing.multiplier * rawValue
    }
}


struct PaddingViewModifier: ViewModifier {
    let spacing: Spacing
    let edge: Edge.Set?

    func body(content: Content) -> some View {
        if let edge {
            content.padding(edge, spacing.value)
        } else {
            content.padding(spacing.value)
        }
    }
}

extension View {
    func pad(_ spacing: Spacing, edge: Edge.Set? = nil) -> some View {
        modifier(PaddingViewModifier(spacing: spacing, edge: edge))
    }
}
