//
//  Offering+PremiumPurchasableCollection.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import EncameraCore
import RevenueCat

extension RevenueCat.Offering: PremiumPurchasableCollection {
    var options: [any PremiumPurchasable] {
        return availablePackages
    }

    var defaultSelection: (any PremiumPurchasable)? {
        let monthlySubscription = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year })
        return monthlySubscription
    }

    func yearlySavings() -> SubscriptionSavings? {

        guard let yearlySubscription = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year }) else {
            return nil
        }
        guard let monthlySubscription = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .month }) else {
            return nil
        }

        let yearlyPriceForMonthlySubscription = 12 * monthlySubscription.storeProduct.price
        let amountSaved = yearlyPriceForMonthlySubscription - yearlySubscription.storeProduct.price

        guard amountSaved > 0 else {
            return nil
        }

        let monthlyPrice = yearlySubscription.storeProduct.price / 12
        guard let yearlyStorekitProduct = yearlySubscription.storeProduct.sk2Product else {
            return nil
        }
        return SubscriptionSavings(totalSavings: amountSaved,
                                   granularPrice: monthlyPrice,
                                   granularPricePeriod: .month,
                                   priceFormatStyle: yearlyStorekitProduct.priceFormatStyle,
                                   subscriptionPeriodUnitFormatStyle: yearlyStorekitProduct.subscriptionPeriodUnitFormatStyle)
    }
}

