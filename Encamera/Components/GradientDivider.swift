//
//  GradientDivider.swift
//  Encamera
//
//  Created by Alexander Freas on 20.09.24.
//

import SwiftUI

struct GradientDivider: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.white.opacity(0.05), location: 0.0),  // 5% at the start
                    .init(color: Color.white.opacity(0.15), location: 0.5),  // 15% in the middle
                    .init(color: Color.white.opacity(0.05), location: 1.0)   // 5% at the end
                ]),
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 1) // Adjust height to match the appearance of Divider
    }
}

#Preview {
    GradientDivider()
}
