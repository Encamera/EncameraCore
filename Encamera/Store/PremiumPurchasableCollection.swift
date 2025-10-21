//
//  PremiumPurchasableCollection.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import EncameraCore

protocol PremiumPurchasableCollection {
    var options: [any PremiumPurchasable] { get }
    var defaultSelection: (any PremiumPurchasable)? { get }
    func yearlySavings() -> SubscriptionSavings?
}

