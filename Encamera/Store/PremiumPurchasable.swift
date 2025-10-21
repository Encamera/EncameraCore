//
//  PremiumPurchasable.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation

protocol PremiumPurchasable: Equatable, Hashable {
    var id: String { get }
    var optionPeriod: String { get }
    var formattedPrice: String { get }
    var billingFrequency: String { get }
    var purchaseActionText: String { get }
    var isEligibleForIntroOffer: Bool { get }
    var isLifetime: Bool { get }
    var isLifetimeUnlimited: Bool { get }
}

