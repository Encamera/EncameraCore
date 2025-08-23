import SwiftUI

enum CircularProgressDisplayMode {
    case percentage(value: Double)
    case countdown(initial: Int, value: Int)
}

struct CircularProgressView: View {
    let lineWidth: CGFloat
    let size: CGFloat
    let displayMode: CircularProgressDisplayMode
    
    init(lineWidth: CGFloat = 4, size: CGFloat = 60, displayMode: CircularProgressDisplayMode) {

        self.lineWidth = lineWidth
        self.size = size
        self.displayMode = displayMode
    }

    var progress: Double {
        switch displayMode {
        case .percentage(let value):
            return value
        case .countdown(let initial, let value):
            guard value >= 0 else {
                return 0
            }
            return Double(value) / Double(initial)
        }
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
                case .percentage(let value):
                    Text("\(Int(value * 100))%")
                        .fontType(.pt12, weight: .semibold)
                        .foregroundColor(.foregroundPrimary)
                case .countdown(_, let value):
                    Text("\(value)")
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
            CircularProgressView(displayMode: .percentage(value: 0.25))
            CircularProgressView(displayMode: .percentage(value: 0.75))
        }
        
        // Countdown mode
        HStack(spacing: 20) {
            CircularProgressView(displayMode: .countdown(initial: 10, value: 8))
            CircularProgressView(displayMode: .countdown(initial: 10, value: 4))
            CircularProgressView(displayMode: .countdown(initial: 10, value: 0))
        }
    }
    .padding()
    .background(Color.background)
} 
