//
//  OnboardingContentView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.09.25.
//

import SwiftUI
import EncameraCore

struct OnboardingContentView<Content: View>: View {
    let imageName: String
    let title: String
    let subtitle: String
    let content: () -> Content
    
    init(
        imageName: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content = { EmptyView() }
    ) {
        self.imageName = imageName
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: .center) {
            Spacer().frame(height: 32)

            ZStack {
                Image(imageName)
                Rectangle()
                    .foregroundColor(.clear)
                    .frame(width: 96, height: 96)
                    .background(Color.actionYellowGreen.opacity(0.1))
                    .cornerRadius(24)
            }
            Spacer().frame(height: 32)
            
            Text(title)
                .fontType(.pt24, weight: .bold)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 12)

            Group {
                Text(subtitle)
                    .fontType(.pt14)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                    .pad(.pt64, edge: .bottom)
            }

            content()
        }
        .frame(width: 290)
    }
}

// Extension to conditionally apply modifiers
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

#Preview {
    OnboardingContentView(
        imageName: "Onboarding-Shield",
        title: "Select Login Method",
        subtitle: "Choose how you want to secure your photos"
    )
}
