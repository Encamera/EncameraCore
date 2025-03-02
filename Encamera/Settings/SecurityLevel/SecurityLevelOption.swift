import SwiftUI

struct SecurityLevelOption: View {
    let title: String
    let securityLevel: String
    let isSelected: Bool
    let action: () -> Void
    
    private var securityBars: Int {
        switch securityLevel.lowercased() {
        case "low protection":
            return 1
        case "moderate protection":
            return 2
        case "strong protection":
            return 3
        default:
            return 0
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .fontType(.pt16, weight: .bold)
                    HStack(spacing: 2) {
                        ForEach(0..<3) { index in
                            Rectangle()
                                .fill(index < securityBars ? Color.actionYellowGreen : Color.gray.opacity(0.3))
                                .frame(width: 12, height: 12)
                        }
                        Text(securityLevel)
                            .fontType(.pt14, weight: .regular)
                            .foregroundColor(.gray)
                            .padding(.leading, 4)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 24))
                } else {
                    Circle()
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                        .frame(width: 24, height: 24)
                }
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
} 