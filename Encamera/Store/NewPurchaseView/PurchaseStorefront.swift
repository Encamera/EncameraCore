//
//  PurchaseStorefront.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.25.
//

import SwiftUI
import EncameraCore

struct PurchaseStorefront: View {
    var currentSubscription: (any PremiumPurchasable)?
    @Binding var purchaseOptions: PremiumPurchasableCollection?
    @State private var selectedPurchasable: (any PremiumPurchasable)? {
        didSet {
            print("Selected didSet", selectedPurchasable)
        }
    }

    var onPurchase: ((any PremiumPurchasable) -> Void)

    init(
        purchaseOptions: Binding<PremiumPurchasableCollection?>,
        initialSelectedPurchasable: (any PremiumPurchasable)? = nil,
        onPurchase: @escaping ((any PremiumPurchasable) -> Void)
    ) {
        self._purchaseOptions = purchaseOptions
        print("initial purchasable", initialSelectedPurchasable)
        self._selectedPurchasable = State(initialValue: initialSelectedPurchasable) // Initialize the @State variable
        self.onPurchase = onPurchase
        
    }

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
                        let _ = print("selected purchasable", selectedPurchasable) // Debugging print
                        if let purchaseOptions {
                            PurchaseOptionComponent(
                                viewModel: .init(optionsCollection: purchaseOptions),
                                selectedOption: $selectedPurchasable
                            ).padding()
                        }
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
//
//#Preview {
//    PurchaseStorefront(purchaseOptions: [
//        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month", savingsPercentage: 0.17),
//        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year", savingsPercentage: 0.0),
//        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time", savingsPercentage: 0.0)
//    ]) { _ in
//
//    }
//}
