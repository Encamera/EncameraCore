import Foundation
import SwiftUI

private struct GradientBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                LinearGradient(
                    gradient: Gradient(colors: [.primaryGradientTop, .primaryGradientBottom]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
    }
}

extension View {
    func gradientBackground() -> some View {
        self.modifier(GradientBackground())
    }
}

#Preview {
    Color.clear.gradientBackground()
}
