//
//  Subscription.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

@dynamicMemberLookup
public struct ServiceSubscription: Identifiable, Equatable {
    public let product: Product
    public var subscriptionInfo: Product.SubscriptionInfo {
        product.subscription.unsafelyUnwrapped
    }
    
    public var id: String { product.id }
    
    init?(subscription: Product) {
        guard subscription.subscription != nil else {
            return nil
        }
        self.product = subscription
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Product, T>) -> T {
        product[keyPath: keyPath]
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Product.SubscriptionInfo, T>) -> T {
        subscriptionInfo[keyPath: keyPath]
    }
    public var priceText: String {
        "\(self.displayPrice)/\(self.subscriptionPeriod.unit.localizedDescription.lowercased())"
    }
}

public struct SubscriptionSavings {
    public let percentSavings: Decimal
    public let granularPrice: Decimal
    public let granularPricePeriod: Product.SubscriptionPeriod.Unit
    
    public init(percentSavings: Decimal, granularPrice: Decimal, granularPricePeriod: Product.SubscriptionPeriod.Unit) {
        self.percentSavings = percentSavings
        self.granularPrice = granularPrice
        self.granularPricePeriod = granularPricePeriod
    }
    
    public var formattedPercent: String {
        return percentSavings.formatted(.percent.precision(.significantDigits(3)))
    }
    
//    @available(iOS 16.0, *)
    public func formattedPrice(for subscription: ServiceSubscription) -> String {
        let currency = granularPrice.formatted(subscription.priceFormatStyle)
        if #available(iOS 16.0, *) {
            let period = granularPricePeriod.formatted(subscription.subscriptionPeriodUnitFormatStyle)
            return "\(currency)/\(period)"
        } else {
            return "Ble"
        }
        
    }
}
