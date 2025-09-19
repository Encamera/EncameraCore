import SwiftUI

struct SignalBarsComponent: View {
    let totalBars: Int
    let activeBars: Int
    
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4
    private let cornerRadius: CGFloat = 8
    private let baseHeight: CGFloat = 2
    
    init(totalBars: Int, activeBars: Int) {
        self.totalBars = totalBars
        // Ensure activeBars doesn't exceed totalBars
        self.activeBars = min(activeBars, totalBars)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        baseHeight + (CGFloat(index) * 4)
    }
    
    private var maxHeight: CGFloat {
        barHeight(for: totalBars - 1)
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(0..<totalBars, id: \.self) { index in
                VStack {
                    Rectangle()
                        .fill(index < activeBars ? Color.actionYellowGreen : Color.gray)
                        .frame(width: barWidth, height: barHeight(for: index))
                        .cornerRadius(cornerRadius, corners: [.topLeft, .topRight])
                }
            }
        }
        .frame(height: maxHeight)
    }
}

// Helper extension to apply corner radius to specific corners
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

#Preview {
    VStack(spacing: 20) {
        SignalBarsComponent(totalBars: 4, activeBars: 1)
        SignalBarsComponent(totalBars: 4, activeBars: 2)
        SignalBarsComponent(totalBars: 4, activeBars: 3)
        SignalBarsComponent(totalBars: 4, activeBars: 4)
    }
    .padding()
    .background(Color.black)
} 
