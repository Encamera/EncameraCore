//
//  ProductOptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.22.
//


import SwiftUI
import StoreKit

struct ProductOptionView: View {
    let product: OneTimePurchase
    let isPurchased: Bool
    
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(product.displayName)
                .fontType(.small, weight: .bold)
            HStack(alignment: .firstTextBaseline) {
                Text(product.description)
                   .fontType(.small)
                Spacer()
                PurchaseButton(priceText: product.priceText, isPurchased: isPurchased) {
                    Task(priority: .userInitiated) {
                        await StoreActor.shared.productController.purchase(product: product)
                    }
                }
            }
        }.productCell()
    }
    
    private var checkmarkImage: some View {
        Image(systemName: isPurchased ? "checkmark.circle.fill" : "circle")
         .symbolRenderingMode(.palette)
         .foregroundStyle(
             isPurchased ? Color.green : Color.background,
             Color.clear,
             Color.foregroundPrimary
         )
         .font(.title2)
    }
    
}

struct ProductOptionView_Previews: PreviewProvider {
    static var previews: some View {
        Text("Hey")
    }
}
