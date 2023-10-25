//
//  GradientBackground.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import Foundation
import SwiftUI

private struct GradientBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Color.background
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image("Onboarding-Background")
                    }
                }
            }.ignoresSafeArea()
        }
    }
}

extension View {
    func gradientBackground() -> some View {
        self.modifier(GradientBackground())
    }
}
