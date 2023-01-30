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
    let subscriptions: [ServiceSubscription]
    let products: [OneTimePurchase]
    let purchasedProducts: [OneTimePurchase]
    @Binding var selectedOption: ServiceSubscription?
    let currentActiveSubscription: ServiceSubscription?
    
    func binding(for subscription: ServiceSubscription) -> Binding<Bool> {
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
        VStack(spacing: 25) {
            if purchasedProducts.isEmpty {
                Text(L10n.subscription)
                    .fontType(.mediumSmall)
                ForEach(subscriptions) { subscription in
                    subscriptionOptionCell(for: subscription)
                }
                
                Text(L10n.oneTimePurchase)
                    .fontType(.mediumSmall)
                ForEach(products) { product in
                    productCell(for: product)
                }
                
            } else {
                ForEach(purchasedProducts) { product in
                    purchasedProductCell(for: product)
                }
                
            }
            
        }.padding(.horizontal)
        
    }
    
    func productCell(for product: OneTimePurchase) -> some View {
        let hasPurchased = purchasedProducts.contains(product)
        return ProductOptionView(
            product: product, isPurchased: hasPurchased
        )
    }
    
    func purchasedProductCell(for product: OneTimePurchase) -> some View {
        return PurchasedProductCell(product: product)
    }
    
    func subscriptionOptionCell(for subscription: ServiceSubscription) -> some View {
        var savingsInfo: SubscriptionSavings?
        if subscription.id == StoreActor.unlimitedYearlyID {
            savingsInfo = self.savings()
        }
        return SubscriptionOptionView(
            subscription: subscription,
            savings: savingsInfo,
            isSubscribed: currentActiveSubscription?.id == subscription.id,
            isOn: binding(for: subscription)
        )
    }
    
    func savings() -> SubscriptionSavings? {
        guard let yearlySubscription = subscriptions.first(where: { $0.id == StoreActor.unlimitedYearlyID }) else {
            return nil
        }
        guard let monthlySubscription = subscriptions.first(where: { $0.id == StoreActor.unlimitedMonthlyID }) else {
            return nil
        }
        
        let yearlyPriceForMonthlySubscription = 12 * monthlySubscription.price
        let amountSaved = yearlyPriceForMonthlySubscription - yearlySubscription.price
        
        guard amountSaved > 0 else {
            return nil
        }
        
        let percentSaved = amountSaved / yearlyPriceForMonthlySubscription
        let monthlyPrice = yearlySubscription.price / 12
        
        return SubscriptionSavings(percentSavings: percentSaved, granularPrice: monthlyPrice, granularPricePeriod: .month)
    }
}
