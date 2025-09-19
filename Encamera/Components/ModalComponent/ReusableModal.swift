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
    @State private var showBackground: Bool = false
    @State private var dragOffset: CGSize = .zero
    
    init(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._isPresented = isPresented
        self.content = content
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                // Full screen overlay with blur - quick fade animation
                Color.clear
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea(.all)
                    .opacity(showBackground ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.2), value: showBackground)
                    .onTapGesture {
                        dismissModal()
                    }
                
                // Modal content pinned to bottom
                ModalContent(
                    content: content,
                    dragOffset: $dragOffset,
                    onDismiss: dismissModal
                )
                .offset(y: showModal ? dragOffset.height : UIScreen.main.bounds.height)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: showModal)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: dragOffset)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom) // Extend frame into safe area
        .onAppear {
            if isPresented {
                // Quick background fade, then modal slide up
                withAnimation(.easeInOut(duration: 0.2)) {
                    showBackground = true
                }
                // Slight delay for modal to create sequence
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        showModal = true
                    }
                }
            }
        }
        .onChange(of: isPresented) { _, presented in
            if presented {
                // Quick background fade, then modal slide up
                withAnimation(.easeInOut(duration: 0.2)) {
                    showBackground = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        showModal = true
                    }
                }
            } else {
                // Immediate modal slide down, then background fade
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showModal = false
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    showBackground = false
                }
            }
        }
    }
    
    private func dismissModal() {
        // Animate modal sliding down first
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showModal = false
        }
        // Then fade background
        withAnimation(.easeInOut(duration: 0.15)) {
            showBackground = false
        }
        // Finally dismiss after animations complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
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
        }
        .safeAreaInset(edge: .bottom) {
            // This creates space for the safe area without using content
            Color.clear.frame(height: 20) // Extra padding beyond safe area
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
