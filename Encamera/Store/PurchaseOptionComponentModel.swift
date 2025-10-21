//
//  PurchaseOptionComponentModel.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation

struct PurchaseOptionComponentModel: PremiumPurchasable, Hashable {
    var id: String = UUID().uuidString
    var optionPeriod: String
    var formattedPrice: String
    var billingFrequency: String
    var purchaseActionText: String = "Purchase"
    var isEligibleForIntroOffer: Bool = false
    var isLifetime: Bool = true
    var isLifetimeUnlimited: Bool = false
    var description: String? = nil
}

