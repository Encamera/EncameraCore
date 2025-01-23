//
//  PurchaseStorefront.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.25.
//

import SwiftUI
import EncameraCore
import RevenueCat


struct PurchaseStorefront: View {

    var currentSubscription: (any PurchaseOptionComponentProtocol)?
    var purchaseOptions: [any PurchaseOptionComponentProtocol]
    var onPurchase: ((any PurchaseOptionComponentProtocol) -> Void)
    @State var selectedPurchasable: (any PurchaseOptionComponentProtocol)?
    var body: some View {
        GeometryReader { geo in

            ZStack(alignment: .top) {
                Image(AppConstants.isInPromoMode ? "HalloweenBG" : "Premium-TopHalo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width)
                    .ignoresSafeArea(.all)

                VStack {
                    ScrollView(showsIndicators: false) {
                        PurchaseUpgradeHeaderView()
                        PurchaseOptionComponent(viewModel: .init(options: purchaseOptions), selectedOption: $selectedPurchasable).padding()
                        PremiumBenefitsScrollView()
                    }
                    StorePurchaseButton(selectedPurchasable: $selectedPurchasable,
                                        isSubscribedToSelectedSubscription: .constant(false),
                                        onPurchase: onPurchase)
                }
            }
        }
    }
}

#Preview {
    PurchaseStorefront(purchaseOptions: [
        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month", savingsPercentage: 0.17),
        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year", savingsPercentage: nil),
        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time", savingsPercentage: nil)
    ]) { _ in

    }
}
