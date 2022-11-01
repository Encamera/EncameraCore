//
//  EncameraProduct.swift
//  Encamera
//
//  Created by Alexander Freas on 26.10.22.
//

import Foundation
import StoreKit

protocol ProductProviding: Identifiable {
    var displayName: String { get }
    var id: String { get }
    var displayPrice: String { get }
    var subscription: Product.SubscriptionInfo? { get }
}

extension Product: ProductProviding {
    
}

struct EncameraProduct: ProductProviding {
    var displayName: String
    
    var id: String
    
    var displayPrice: String
    
    var subscription: Product.SubscriptionInfo?
    
    static var monthly = EncameraProduct(displayName: "Unlimited Monthly", id: "123", displayPrice: "$0.99")
    static var yearly = EncameraProduct(displayName: "Unlimited Yearly", id: "456", displayPrice: "$9.99")
    
    static var products = [
        monthly,
        yearly
    ]
    
}
