//
//  MovingGradient.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.25.
//

import Foundation
import SwiftUI
extension Color {
    static let silver = Color(white: 0.75)
    static let orange = Color.orange
}

struct MovingGradient: ViewModifier {
    @State private var gradientPosition: CGFloat = 0.0

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.silver, Color.white, Color.silver]),
                            startPoint: .leading,
                            endPoint: UnitPoint(x: gradientPosition, y: 0)
                        ),
                        lineWidth: 2
                    )
            )
            .onAppear {
                withAnimation(Animation.linear(duration: 2).repeatForever(autoreverses: true)) {
                    gradientPosition = 1.0
                }
            }
    }
}
