import SwiftUI

enum CircularProgressDisplayMode {
    case percentage
    case countdown(seconds: Int)
}

struct CircularProgressView: View {
    let progress: Double
    let lineWidth: CGFloat
    let size: CGFloat
    let displayMode: CircularProgressDisplayMode
    
    init(progress: Double, lineWidth: CGFloat = 4, size: CGFloat = 60, displayMode: CircularProgressDisplayMode = .percentage) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.size = size
        self.displayMode = displayMode
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
            
            // Display text based on mode
            Group {
                switch displayMode {
                case .percentage:
                    Text("\(Int(progress * 100))%")
                        .fontType(.pt12, weight: .semibold)
                        .foregroundColor(.foregroundPrimary)
                case .countdown(let seconds):
                    Text("\(seconds)")
                        .fontType(.pt16, weight: .bold)
                        .foregroundColor(.foregroundPrimary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    VStack(spacing: 20) {
        // Percentage mode
        HStack(spacing: 20) {
            CircularProgressView(progress: 0.25, displayMode: .percentage)
            CircularProgressView(progress: 0.75, displayMode: .percentage)
        }
        
        // Countdown mode
        HStack(spacing: 20) {
            CircularProgressView(progress: 0.2, displayMode: .countdown(seconds: 5))
            CircularProgressView(progress: 0.6, displayMode: .countdown(seconds: 3))
            CircularProgressView(progress: 1.0, displayMode: .countdown(seconds: 0))
        }
    }
    .padding()
    .background(Color.background)
} 