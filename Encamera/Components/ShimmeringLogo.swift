import SwiftUI

struct ShimmerEffect: ViewModifier {
    @State private var isAnimating = false
    let shimmerWidth: CGFloat
    
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .center) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.5),
                                Color.white.opacity(0.0)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: isAnimating ? geometry.size.width / 2 + shimmerWidth : -shimmerWidth - geometry.size.width / 2)
                    .mask(content)
                    .blendMode(.screen)
            }
            .onAppear {
                withAnimation(
                    Animation.linear(duration: 2.5)
                        .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
        }
    }
}

extension View {
    func shimmer(shimmerWidth: CGFloat = 500.0) -> some View {
        modifier(ShimmerEffect(shimmerWidth: shimmerWidth))
    }
}

struct ShimmeringLogo: View {
    let text: String
    let subtitle: String
    let shimmerWidth: CGFloat
    
    init(text: String = "Encamera", subtitle: String = "", shimmerWidth: CGFloat = 500.0) {
        self.text = text
        self.subtitle = subtitle
        self.shimmerWidth = shimmerWidth
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .fontType(.pt32, weight: .bold)
                .shimmer(shimmerWidth: shimmerWidth)
            
            if !subtitle.isEmpty {
                Text(subtitle)
                    .fontType(.pt16)
                    .shimmer(shimmerWidth: shimmerWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ShimmeringLogo_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.blue
            ShimmeringLogo(subtitle: "Secure Camera")
        }
        .ignoresSafeArea()
    }
} 
