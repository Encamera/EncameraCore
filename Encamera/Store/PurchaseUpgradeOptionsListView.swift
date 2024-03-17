//
//  PurchaseUpgradeOptionsListView.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI
import StoreKit
import EncameraCore

struct PurchasedProductCell: View {
    
    @State private var transactionDate: Date?
    let product: OneTimePurchase
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(L10n.purchased(product.displayName))
                if let transactionDate = transactionDate {
                    Text(DateUtils.dateOnlyString(from:  transactionDate))
                }
                Text(L10n.thankYouForYourSupport)
            }
        }
        .frame(maxWidth: .infinity)
        .productCell()
        .task {
            transactionDate = await product.product.latestTransaction?.signedDate
        }
    }
}

struct PurchaseUpgradeOptionsListView: View {
    let subscriptionOptions: [ServiceSubscription]
    let oneTimePurchaseOptions: [OneTimePurchase]
    let purchasedProduct: OneTimePurchase?
    
    @Binding var selectedOption: (any Purchasable)?
    let currentActiveSubscription: ServiceSubscription?
    let freeUnlimitedTapped: () -> ()
    let onPurchase: () -> ()
    @Environment(\.dismiss) private var dismiss

    func binding(for subscription: any Purchasable) -> Binding<Bool> {
        return Binding {
            selectedOption?.id == subscription.id
        } set: { newValue in
            selectedOption = newValue ? subscription : nil
        }
    }
    
    var body: some View {
        /*
         This is setup this way because currently there
         is only one "premium" purchasable product or
         subscription. When there are more, this will need
         to be updated.
         */
        VStack(spacing: 16) {
            if let purchasedProduct  {
                purchasedProductCell(for: purchasedProduct)
            } else {
                ForEach(subscriptionOptions) { subscription in
                    subscriptionOptionCell(for: subscription)
                }
                ForEach(oneTimePurchaseOptions) { oneTimePurchase in
                    subscriptionOptionCell(for: oneTimePurchase)
                }
                if let oneTimePurchase = selectedOption as? OneTimePurchase {
                    SubscriptionPurchaseButton(selectedPurchasable: oneTimePurchase) {
                        onPurchase()
                    }
                } else if let subscription = selectedOption as? ServiceSubscription {
                    SubscriptionPurchaseButton(selectedPurchasable: subscription) {
                        onPurchase()
                    }
                }
            }
        }.padding(.horizontal)
        
    }
    

    
    func purchasedProductCell(for product: OneTimePurchase) -> some View {
        return PurchasedProductCell(product: product)
    }
    
    func subscriptionOptionCell(for subscription: any Purchasable) -> some View {
        
        return SubscriptionOptionView(
            subscription: subscription,
            isSubscribed: currentActiveSubscription?.id == subscription.id,
            isOn: binding(for: subscription)
        )
    }
    
}
