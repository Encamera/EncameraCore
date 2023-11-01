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
        VStack(alignment: .leading, spacing: 5) {
            Group {
                Text(L10n.getPremium)
                    .fontType(.pt24, on: .darkBackground, weight: .bold)
                Text(L10n.premiumUnlockTheseBenefits)
                    .fontType(.pt14)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)

    }
}

struct PurchaseUpgradeHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        PurchaseUpgradeHeaderView()
    }
}
