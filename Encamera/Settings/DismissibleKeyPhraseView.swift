//
//  DismissibleKeyPhraseView.swift
//  Encamera
//
//  Created by Alexander Freas on $(DATE).
//

import SwiftUI
import EncameraCore

struct DismissibleKeyPhraseView: View {
    @StateObject var viewModel: KeyPhraseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGSize = .zero
    
    var body: some View {
        VStack(spacing: 0) {
            // Swipe indicator
            HStack {
                Spacer()
                SwipeIndicator()
                Spacer()
            }
            .padding(.top, 12)
            
            // Key phrase content - remove its own gradient background
            KeyPhraseView(viewModel: viewModel)
                .background(Color.clear)
        }
        .background(
            // Use the app's primary gradient colors
            LinearGradient(
                gradient: Gradient(colors: [.primaryGradientTop, .primaryGradientBottom]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedCorner(radius: 20, corners: [.topLeft, .topRight]))
        .offset(y: dragOffset.height > 0 ? dragOffset.height : 0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation
                    }
                }
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    } else {
                        withAnimation(.spring()) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .onTapGesture(coordinateSpace: .global) { location in
            // Only dismiss if tapping the swipe indicator area
            if location.y < 50 {
                dismiss()
            }
        }
    }
}

#Preview {
    DismissibleKeyPhraseView(viewModel: .init(keyManager: DemoKeyManager()))
}
