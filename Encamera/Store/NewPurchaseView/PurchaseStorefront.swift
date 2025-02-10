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
    @State var currentSubscription: (any PremiumPurchasable)?
    var purchaseOptions: PremiumPurchasableCollection
    @State var selectedPurchasable: (any PremiumPurchasable)?
    var onPurchase: ((any PremiumPurchasable) -> Void)

    private func loadEntitlement() async  {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            let filteredSubs = purchaseOptions.options.filter { option in
                customerInfo.allPurchasedProductIdentifiers.contains(option.id)
            }
            let sub = filteredSubs.sorted(by: {$0.isLifetime && !$1.isLifetime}).first
            currentSubscription = sub
        } catch {
        }

    }

    var showPurchaseOptions: Bool {
        if let currentSubscription {
            return currentSubscription.isLifetime == false
        }
        return true
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
                        PurchaseUpgradeHeaderView(purchasedProduct: currentSubscription)
                        if showPurchaseOptions {
                            PurchaseOptionComponent(
                                viewModel: .init(optionsCollection: purchaseOptions),
                                selectedOption: $selectedPurchasable,
                                defaultOption: selectedPurchasable
                            ).padding()
                        }
                        PremiumBenefitsScrollView(isPremium: Binding<Bool> {
                            return currentSubscription != nil
                        } set: { _ in
                        })
                    }
                    if showPurchaseOptions {
                        StorePurchaseButton(selectedPurchasable: $selectedPurchasable,
                                            activePurchase: $currentSubscription,
                                            onPurchase: onPurchase)
                        .padding()
                    }
                }.frame(maxWidth: 600)
            }
            .onAppear {
                let defaultSelection = purchaseOptions.defaultSelection
                selectedPurchasable = defaultSelection
            }
            .task {
                await loadEntitlement()
            }
        }
    }
}
//
#Preview {
    PurchaseStorefront(purchaseOptions: PurchaseOptionCollectionModel(options: [
        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month"),
        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year"),
        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time")
    ]), onPurchase: { _ in

    })
}
