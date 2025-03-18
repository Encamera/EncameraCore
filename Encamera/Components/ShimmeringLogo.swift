import SwiftUI

struct ShimmeringLogo: View {
    @State private var isAnimating = false
    let text: String
    let fontSize: CGFloat
    let shimmerWidth: CGFloat
    
    init(text: String = "Encamera", fontSize: CGFloat = 36, shimmerWidth: CGFloat = 500.0) {
        self.text = text
        self.fontSize = fontSize
        self.shimmerWidth = shimmerWidth
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
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
                    .frame(width: shimmerWidth)
                    .offset(x: isAnimating ? geometry.size.width + shimmerWidth : -shimmerWidth - geometry.size.width)
                    .mask(
                        Text(text)
                            .font(.system(size: fontSize, weight: .bold))
                    )
                    .blendMode(.screen)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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

struct ShimmeringLogo_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.blue
            ShimmeringLogo()
                .frame(width: 300, height: 100)
        }
        .ignoresSafeArea()
    }
} 
