//
//  Subscription.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

@dynamicMemberLookup
struct ServiceSubscription: Identifiable, Equatable {
    let product: Product
    var subscriptionInfo: Product.SubscriptionInfo {
        product.subscription.unsafelyUnwrapped
    }
    
    var id: String { product.id }
    
    init?(subscription: Product) {
        guard subscription.subscription != nil else {
            return nil
        }
        self.product = subscription
    }
    
    subscript<T>(dynamicMember keyPath: KeyPath<Product, T>) -> T {
        product[keyPath: keyPath]
    }
    
    subscript<T>(dynamicMember keyPath: KeyPath<Product.SubscriptionInfo, T>) -> T {
        subscriptionInfo[keyPath: keyPath]
    }
    var priceText: String {
        "\(self.displayPrice)/\(self.subscriptionPeriod.unit.localizedDescription.lowercased())"
    }
}

struct SubscriptionSavings {
    let percentSavings: Decimal
    let granularPrice: Decimal
    let granularPricePeriod: Product.SubscriptionPeriod.Unit
    
    init(percentSavings: Decimal, granularPrice: Decimal, granularPricePeriod: Product.SubscriptionPeriod.Unit) {
        self.percentSavings = percentSavings
        self.granularPrice = granularPrice
        self.granularPricePeriod = granularPricePeriod
    }
    
    var formattedPercent: String {
        return percentSavings.formatted(.percent.precision(.significantDigits(3)))
    }
    
//    @available(iOS 16.0, *)
    func formattedPrice(for subscription: ServiceSubscription) -> String {
        let currency = granularPrice.formatted(subscription.priceFormatStyle)
        if #available(iOS 16.0, *) {
            let period = granularPricePeriod.formatted(subscription.subscriptionPeriodUnitFormatStyle).lowercased()
            return "\(currency)/\(period)"
        } else {
            return "Ble"
        }
        
    }
}
