//
//  PurchaseUpgradeHeaderView.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI
import EncameraCore


struct PurchaseUpgradeHeaderView: View {
    
    var body: some View {
        VStack(spacing: 5) {
            Image("EncameraPremiumHeader")
            Group {
                Text(L10n.viewUnlimitedPhotosForEachKey)
                Text(L10n.createAnUnlimitedNumberOfKeys)
                Text(L10n.supportPrivacyFocusedDevelopment)
            }
            .fontType(.small)
            HStack(spacing: 10) {
                Button(L10n.enterPromoCode) {
                    Task {
                        await StoreActor.shared.presentCodeRedemptionSheet()
                    }
                }
                .fontType(.small, on: .elevated)
                .textPill(color: .green)
            }
            
        }
        .padding(.top, 0)
        .padding(.bottom, 30)
    }
}

struct PurchaseUpgradeHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        PurchaseUpgradeHeaderView()
    }
}
