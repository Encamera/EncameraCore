import SwiftUI

struct CircularProgressView: View {
    let progress: Double
    let lineWidth: CGFloat
    let size: CGFloat
    
    init(progress: Double, lineWidth: CGFloat = 4, size: CGFloat = 60) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.size = size
    }
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.secondaryElementColor.opacity(0.2), lineWidth: lineWidth)
            
            // Progress circle
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.actionYellowGreen,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
            
            // Percentage text
            Text("\(Int(progress * 100))%")
                .fontType(.pt12, weight: .semibold)
                .foregroundColor(.foregroundPrimary)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    VStack(spacing: 20) {
        CircularProgressView(progress: 0.0)
        CircularProgressView(progress: 0.25)
        CircularProgressView(progress: 0.5)
        CircularProgressView(progress: 0.75)
        CircularProgressView(progress: 1.0)
    }
    .padding()
    .background(Color.background)
} 