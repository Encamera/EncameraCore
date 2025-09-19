//
//  ReusableModal.swift
//  Encamera
//
//  Created by Assistant on 19.09.25.
//

import SwiftUI
import EncameraCore

// MARK: - Parent Modal Component
struct ReusableModal<Content: View>: View {
    @Binding var isPresented: Bool
    let content: () -> Content
    
    @State private var showModal: Bool = false
    @State private var dragOffset: CGSize = .zero
    
    init(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._isPresented = isPresented
        self.content = content
    }
    
    var body: some View {
        ZStack {
            if isPresented {
                // Full screen overlay with blur
                Color.clear
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea(.all)
                    .onTapGesture {
                        dismissModal()
                    }
                
                // Modal content
                ModalContent(
                    content: content,
                    dragOffset: $dragOffset,
                    onDismiss: dismissModal
                )
                .offset(y: showModal ? dragOffset.height : UIScreen.main.bounds.height)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: showModal)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dragOffset)
            }
        }
        .onAppear {
            showModal = true
        }
        .onChange(of: isPresented) { presented in
            if presented {
                showModal = true
            } else {
                showModal = false
            }
        }
    }
    
    private func dismissModal() {
        showModal = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isPresented = false
            dragOffset = .zero
        }
    }
}

// MARK: - Child Modal Content Component
private struct ModalContent<Content: View>: View {
    let content: () -> Content
    @Binding var dragOffset: CGSize
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Swipe indicator
            SwipeIndicator()
                .padding(.top, 12)
            
            // Content
            content()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 0)
                .padding(.bottom, 34) // Safe area bottom padding
        }
        .gradientBackground()
        .clipShape(
            RoundedCorner(radius: 24, corners: [.topLeft, .topRight])
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow downward dragging
                    if value.translation.height > 0 {
                        dragOffset = value.translation
                    }
                }
                .onEnded { value in
                    // Dismiss if dragged down more than 100 points or with sufficient velocity
                    if value.translation.height > 100 || value.predictedEndTranslation.height > 200 {
                        onDismiss()
                    } else {
                        // Spring back to original position
                        dragOffset = .zero
                    }
                }
        )
    }
}


// MARK: - View Extension
extension View {
    func reusableModal<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ZStack {
            self
            
            ReusableModal(isPresented: isPresented, content: content)
        }
    }
}

// MARK: - Preview
#Preview {
    VStack {
        Color.blue
            .ignoresSafeArea()
    }
    .reusableModal(isPresented: .constant(true)) {
        VStack(spacing: 24) {
            Image(systemName: "key.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(.orange)
            
            Text("Back up your Encryption Key")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Your photos are protected with a unique encryption key. This is the only way to recover your images if you switch devices or reinstall the app.")
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Text("We cannot help you recover lost photos without this key.")
                .font(.body)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button("View the Key") {
                // Action
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .foregroundColor(.black)
            .cornerRadius(12)
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 40)
    }
}
