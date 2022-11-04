//
//  PurchasePhotoSubscriptionOverlay.swift
//  Encamera
//
//  Created by Alexander Freas on 16.10.22.
//

import SwiftUI

struct PurchasePhotoSubscriptionOverlay: View {
    
    var upgradeTapped: () -> Void
    
    var body: some View {
        
        VStack(alignment: .center) {
            Image("EncameraPremiumHeader")
            Text("Upgrade to view unlimited photos")
                .fontType(.large)
                .multilineTextAlignment(.center)
            Button(action: upgradeTapped, label: {
                Text("Tap to Upgrade")
            }).primaryButton()
        }
    
    }
}

struct PurchasePhotoSubscriptionOverlay_Previews: PreviewProvider {
    static var previews: some View {
        PurchasePhotoSubscriptionOverlay() {
            
        }
            .preferredColorScheme(.dark)
    }
}
