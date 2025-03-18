import SwiftUI

struct ShimmeringLogo: View {
    @State private var isAnimating = false
    let text: String
    let shimmerWidth: CGFloat
    
    init(text: String = "Encamera", shimmerWidth: CGFloat = 500.0) {
        self.text = text
        self.shimmerWidth = shimmerWidth
    }
    
    var body: some View {
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
                    .mask(
                        Text(text)
                            .fontType(.pt32, weight: .bold)
                    )
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
        .frame(maxWidth: .infinity, alignment: .center)

    }
}

struct ShimmeringLogo_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.blue
            ShimmeringLogo()
        }
        .ignoresSafeArea()
    }
} 
