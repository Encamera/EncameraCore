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
            ZStack(alignment: .trailing) {
                Color.background
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .trailing, spacing: 0) {
                    Image("Background-Top")
                        .resizable()
                    Spacer()
                    Image("Background-Bottom")
                        .resizable()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.zero)
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
