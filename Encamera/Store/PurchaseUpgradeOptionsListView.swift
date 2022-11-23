//
//  PurchaseUpgradeOptionsListView.swift
//  Encamera
//
//  Created by Alexander Freas on 23.11.22.
//

import SwiftUI
import StoreKit

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
        VStack {
            ForEach(products) { product in
                productCell(for: product)
            }
            ForEach(subscriptions) { subscription in
                subscriptionOptionCell(for: subscription)
            }
        }.padding(.horizontal)
            
    }
    
    func productCell(for product: OneTimePurchase) -> some View {
        let hasPurchased = purchasedProducts.contains(product)
        return ProductOptionView(
            product: product, isPurchased: hasPurchased
        )
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
