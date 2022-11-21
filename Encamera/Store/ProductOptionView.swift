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

    @Environment(\.colorScheme) private var colorScheme
    
    
    private static var backgroundColor: Color {
        .foregroundSecondary
    }
    
    private static var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.displayName)
                    .fontType(.small, weight: .bold)
                Spacer()
                PurchaseButton(priceText: product.priceText, isPurchased: isPurchased) {
                    Task(priority: .userInitiated) {
                        await StoreActor.shared.productController.purchase()
                    }
                }
            }
            Text(product.description)
               .fontType(.small)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Self.backgroundColor, in: Self.backgroundShape)
        
        .padding(.vertical, 5.0)
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
