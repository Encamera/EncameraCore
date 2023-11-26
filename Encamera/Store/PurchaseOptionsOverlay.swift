//
//  PurchaseOptionsOverlay.swift
//  Encamera
//
//  Created by Alexander Freas on 30.10.23.
//

import SwiftUI

struct PurchaseOptionsOverlay: View {

    

    var body: some View {
        VStack {
            OptionItemView(
                title: "Yearly Plan", 
                description: "12 Months - $107",
                isAvailable: true,
                isSelected:.constant(true)
            )
            
        }
    }
}

#Preview {
    PurchaseOptionsOverlay()
}
