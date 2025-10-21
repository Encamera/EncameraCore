//
//  PurchaseOptionComponentViewModel.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import EncameraCore

class PurchaseOptionComponentViewModel: ObservableObject {
    @Published var optionsCollection: PremiumPurchasableCollection

    var savingsString: String? {
        guard let savings = optionsCollection.yearlySavings() else { return nil }
        return savings.formattedTotalSavings
    }

    init(optionsCollection: PremiumPurchasableCollection) {
        self.optionsCollection = optionsCollection
    }
}

