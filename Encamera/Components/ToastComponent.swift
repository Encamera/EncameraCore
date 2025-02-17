import SwiftUI

struct Toast: View {
    private let spacing: CGFloat = 12
    private let horizontalPadding: CGFloat = 9
    private let cornerRadius: CGFloat = 30
    private let strokeWidth: CGFloat = 2
    
    let message: String
    let needsAdditionalPadding: Bool

    var body: some View {
        HStack(spacing: spacing) {
            Image("CheckCircle")
                .resizable()
                .frame(width: 36, height: 36)
            Text(message)
                .fontType(.pt14, weight: .bold)
                .foregroundColor(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(horizontalPadding)
        .background(Color.inputFieldBackgroundColor)
        .cornerRadius(cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.disabledButtonTextColor, lineWidth: strokeWidth)
        )
        .padding(.vertical, needsAdditionalPadding ? 44 : 0)
    }
}

struct ToastModifier: ViewModifier {
    @Binding var isShowing: Bool
    let message: String
    let needsAdditionalPadding: Bool

    func body(content: Content) -> some View {
        ZStack {
            content
            
            ZStack {
                VStack(alignment: .center) {
                    Toast(message: message, needsAdditionalPadding: needsAdditionalPadding)
                        .onChange(of: isShowing, { oldValue, newValue in
                            guard newValue == true else { return }
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                isShowing = false
                            }
                        })
                        .zIndex(1)
                        .padding(Spacing.pt16.value)
                        .onTapGesture {
                            isShowing = false
                        }
                    Spacer()
                }
            }
            .opacity(isShowing ? 1 : 0)
            .animation(.easeInOut, value: isShowing)
            .transition(.move(edge: .top))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func toast(isShowing: Binding<Bool>, message: String, needsAdditionalPadding: Bool = false) -> some View {
        modifier(ToastModifier(isShowing: isShowing, message: message, needsAdditionalPadding: needsAdditionalPadding))
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var showToast = false
        
        var body: some View {
            VStack {
                Text("Background Content")
                    .toast(isShowing: $showToast, message: "Action completed successfully!")
                
                Button("Toggle Toast") {
                        showToast.toggle()

                }
                .padding()
            }
        }
    }
    
    return PreviewWrapper()
}

