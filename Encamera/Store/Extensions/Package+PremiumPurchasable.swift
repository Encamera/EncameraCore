//
//  Package+PremiumPurchasable.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import EncameraCore
import RevenueCat

// Lifetime product identifiers
private let lifetimeProductIDs: Set<String> = [
    "purchase.lifetimelimited",
    "purchase.lifetimeunlimitedbasic"
]

extension Package: PremiumPurchasable {

    var id: String {
        return storeProduct.productIdentifier
    }

    var optionPeriod: String {
        return storeProduct.localizedTitle
    }

    // Returns the display price of the product
    var formattedPrice: String {
        guard let product = self.storeProduct.sk2Product else {
            return ""
        }
        return product.displayPrice
    }

    // This should return "per month", "per year", or "one time"
    var billingFrequency: String {
        guard let product = self.storeProduct.sk2Product else {
            return ""
        }

        if product.type == .autoRenewable {
            if let subscriptionPeriod = product.subscription?.subscriptionPeriod {
                switch subscriptionPeriod.unit {
                case .month:
                    return "per month"
                case .year:
                    return "per year"
                default:
                    return ""
                }
            }
        } else if product.type == .nonConsumable {
            return "one time"
        }

        return ""
    }


    // Text for purchase action
    var purchaseActionText: String {
        return "Purchase"
    }

    // Eligibility for introductory offers
    var isEligibleForIntroOffer: Bool {
        guard let product = self.storeProduct.sk2Product else {
            return false
        }
        return product.subscription?.introductoryOffer != nil
    }
    
    var isLifetime: Bool {
        return lifetimeProductIDs.contains(storeProduct.productIdentifier)
    }
}

