import SwiftUI

struct SecurityLevelOption: View {
    let title: String
    let securityLevel: String
    let isSelected: Bool
    let action: () -> Void
    
    
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .fontType(.pt16, weight: .bold)
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