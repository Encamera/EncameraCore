import SwiftUI

enum AuthenticationMethodType: String, CaseIterable {
    case faceID = "Face ID only"
    case pinCode = "PIN Code"
    case password = "Password"
    
    var securityLevel: String {
        switch self {
        case .faceID:
            return "Low protection"
        case .pinCode:
            return "Moderate protection"
        case .password:
            return "Strong protection"
        }
    }
}

struct AuthenticationMethodView: View {
    @State private var selectedMethod: AuthenticationMethodType = .faceID
    @Environment(\.presentationMode) private var presentationMode
    
    private func popLastView() {
        presentationMode.wrappedValue.dismiss()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("PLEASE SELECT A METHOD")
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                VStack(spacing: 16) {
                    ForEach(AuthenticationMethodType.allCases, id: \.self) { method in
                        SecurityLevelOption(
                            title: method.rawValue,
                            securityLevel: method.securityLevel,
                            isSelected: selectedMethod == method
                        ) {
                            selectedMethod = method
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewHeader(
                    title: "Authentication method",
                    isToolbar: true,
                    textAlignment: .center,
                    titleFont: .pt18,
                    leftContent: {
                        Button(action: popLastView) {
                            Image(systemName: "chevron.left")
                                .fontType(.pt18, weight: .bold)
                        }
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .navigationBarBackButtonHidden()
        .gradientBackground()
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView()
    }
} 