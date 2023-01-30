//
//  ExplanationForUpgradeTutorial.swift
//  Encamera
//
//  Created by Alexander Freas on 03.11.22.
//

import SwiftUI
import EncameraCore


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
            Text(L10n.wantMore)
                .fontType(.large)
            Group {
                Text(L10n.supportPrivacyFocusedDevelopmentByUpgrading)
                Text(L10n.viewUnlimitedPhotos😍)
                Text(L10n.createUnlimitedKeys🔑)
            }
            .fontType(.mediumSmall)
            HStack {
                Group {
                    Button(L10n.freeTrial) {
                        withAnimation {
                            shouldShow = false
                            showUpgrade = true
                        }
                    }
                    Button(L10n.noThanks) {
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
