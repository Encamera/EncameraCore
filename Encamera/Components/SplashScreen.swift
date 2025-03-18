import SwiftUI

struct SplashScreen<Content: View>: View {
    @State private var isActive = false
    @State private var opacity = 1.0
    let content: () -> Content
    
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    
    var body: some View {
        if isActive {
            content()
        } else {
            ZStack {

                VStack {
                    Spacer()
                    Image("LogoSquare")
                    ShimmeringLogo(text: "Encamera")
                        .opacity(opacity)
                        .frame(maxWidth: .infinity, maxHeight: 55, alignment: .center)
                    Spacer()
                }

            }
            .onAppear {
                // Delay for 1.5 seconds, then start fade out
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Fade out animation
                    withAnimation(.easeOut(duration: 0.5)) {
                        self.opacity = 0.0
                    }
                    
                    // After fade out, set isActive to true to show main content
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.isActive = true
                    }
                }
            }
            .gradientBackground()
        }
    }
}

struct SplashScreen_Previews: PreviewProvider {
    static var previews: some View {
        SplashScreen {
            ZStack {
                Color.red
                Text("Main App Content")
            }
            .ignoresSafeArea()
        }
    }
} 
