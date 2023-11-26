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
                VStack(alignment: .leading) {
                    Image("Background-TopLeftGradient")
                        .resizable()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .background(Color.orange)

                VStack(alignment: .trailing) {
                    Image("Background-Top")
                        .frame(maxWidth: .infinity)
                    Spacer()
                    Image("Background-Bottom")
                }
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
