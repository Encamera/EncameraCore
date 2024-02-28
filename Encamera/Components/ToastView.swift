import SwiftUI

struct ToastView: View {
    var text: String
    @Binding var isShowing: Bool

    var body: some View {
        if isShowing {
            Text(text)
                .foregroundColor(Color.purple)
                .padding()
                .background(Color.white)
                .cornerRadius(10)
                .shadow(radius: 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: isShowing)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            isShowing = false
                        }
                    }
                }
                .padding(.bottom, 50)
        }
    }
}

struct ContentView: View {
    @State private var showToast = false

    var body: some View {
        ZStack {
            Button("Show Toast") {
                withAnimation {
                    showToast = true
                }
            }
            ToastView(text: "Notification Text", isShowing: $showToast)
        }
    }
}
