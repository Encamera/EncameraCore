//
//  ExplanationForUpgradeTutorial.swift
//  Encamera
//
//  Created by Alexander Freas on 03.11.22.
//

import SwiftUI

protocol TutorialView {
    var shouldShow: Bool { get }
    
    
}

extension TutorialView {
    var spacing: CGFloat {
        25.0
    }
}

struct ExplanationForUpgradeTutorial: View, TutorialView {
    
    @Binding var shouldShow: Bool
    @Binding var showUpgrade: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text("Want more?")
                .fontType(.large)
            Group {
                Text("Support privacy-focused development by upgrading!")
                Text("View unlimited photos 😍 ")
                Text("Create unlimited keys 🔑 ")
            }
            .fontType(.mediumSmall)
            HStack {
                Group {
                    Button("Free Trial") {
                        withAnimation {
                            shouldShow = false
                            showUpgrade = true
                        }
                    }
                    Button("No, thanks") {
                        withAnimation {
                            shouldShow = false
                        }
                        
                    }
                }.primaryButton(on: .elevated)
            }
        }
        .padding()
        .background(Color.foregroundSecondary)
        .cornerRadius(AppConstants.defaultCornerRadius)
    }
}

struct ExplanationForUpgradeTutorial_Previews: PreviewProvider {
    static var previews: some View {
        ExplanationForUpgradeTutorial(shouldShow: .constant(true), showUpgrade: .constant(false))
            .preferredColorScheme(.dark)
    }
}
