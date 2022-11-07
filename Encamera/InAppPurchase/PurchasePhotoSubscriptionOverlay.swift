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
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .center) {
                Image("EncameraPremiumHeader")
                Text("Upgrade to view unlimited photos")
                    .fontType(.large)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                Button(action: upgradeTapped, label: {
                    Text("Tap to Upgrade")
                })
                .primaryButton()
            }            
        }
    }
}

struct PurchasePhotoSubscriptionOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Image("dog").resizable().aspectRatio(contentMode: .fit)
            PurchasePhotoSubscriptionOverlay() {
                
            }
        }
            .preferredColorScheme(.dark)
    }
}
