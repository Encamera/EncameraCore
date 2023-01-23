//
//  PurchaseButton.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.22.
//

import SwiftUI

struct PurchaseButton: View {
    
    var priceText: String
    var isPurchased: Bool
    var action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            
            Button {
                if isPurchased == false {
                    action()
                }
            } label: {
                if isPurchased {
                    Text(Image(systemName: "checkmark"))
                        .bold()
                        .foregroundColor(.foregroundSecondary)
                } else {
                    Text(priceText)
                }
            }
            .buttonStyle(BuyButtonStyle(isPurchased: isPurchased))
        }
        .frame(maxWidth: 120)
    }
}

struct PurchaseButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            Text("Buy me")
            PurchaseButton(priceText: "$3.99", isPurchased: true) {
                
            }
            PurchaseButton(priceText: "$3.99", isPurchased :false) {
                
            }
        }.preferredColorScheme(.dark)
        
    }
}
