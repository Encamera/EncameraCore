//
//  PurchaseUpgradeHeaderView.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI


struct PurchaseUpgradeHeaderView: View {

var body: some View {
   VStack(spacing: 5) {
       Image("EncameraPremiumHeader")
       Group {
           Text("View unlimited photos for each key.")
           Text("Create an unlimited number of keys.")
           Text("Support privacy-focused development.")
       }
       .fontType(.small)
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
