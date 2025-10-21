//
//  PurchaseOptionCollectionModel.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import EncameraCore

struct PurchaseOptionCollectionModel: PremiumPurchasableCollection {
    var defaultSelection: (any PremiumPurchasable)?
    var options: [any PremiumPurchasable]

    func yearlySavings() -> SubscriptionSavings? {
        return nil
    }
}

