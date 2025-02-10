//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI
import EncameraCore

struct SubscriptionPurchaseButton<T: Purchasable>: View {

    
    var subscriptionController: StoreSubscriptionController = StoreActor.shared.subscriptionController
    @State private var canRedeemIntroOffer = false
    @State private var redeemSheetIsPresented = false
    
    @Environment(\.dismiss) private var dismiss
    
    let selectedPurchasable: T?
    let onPurchase: () -> Void

    init(selectedPurchasable: T, onPurchase: @escaping () -> Void) {
        self.onPurchase = onPurchase
        self.selectedPurchasable = selectedPurchasable
    }

    func checkSubscriptionStatus()  {
        canRedeemIntroOffer = false
        guard let subscription = selectedPurchasable as? ServiceSubscription else {
            return
        }
        let selectedSubscription = subscription.subscriptionInfo
        Task { @MainActor in
            print("Checking for intro offer eligibility")
            self.canRedeemIntroOffer = await selectedSubscription.isEligibleForIntroOffer && selectedSubscription.introductoryOffer != nil
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                onPurchase()
            } label: {
                Group {
                    if let selectedPurchasable {
                        if canRedeemIntroOffer {
                            VStack {
                                Text(L10n.startTrialOffer)
                                Text(AppConstants.isInPromoMode ? L10n.promoFreeTrialTerms(selectedPurchasable.priceText) : L10n.freeTrialTerms(selectedPurchasable.priceText))
                                    .fontType(.pt12, on: .primaryButton)
                            }
                        } else if StoreActor.shared.hasPurchased(product: selectedPurchasable) {
                            Text(L10n.subscribed)
                        } else {
                            Text(selectedPurchasable.purchaseActionText)
                        }
                    } else {
                        Text(L10n.selectProduct)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .primaryButton(enabled: !subscribedToSelectedSubscription)
            .disabled(selectedPurchasable == nil || subscribedToSelectedSubscription)

            Spacer().frame(height: 8)
            Text(L10n.noCommitmentCancelAnytime)
                .fontType(.pt14, weight: .bold)
                .opacity(0.8)
        }
        .onAppear {
            checkSubscriptionStatus()
        }
        .frame(maxWidth: .infinity)
        .onChange(of: selectedPurchasable) { newValue, _ in
            checkSubscriptionStatus()
        }
    }

    @MainActor
    private var subscribedToSelectedSubscription: Bool {
        return StoreActor.shared.hasPurchased(product: selectedPurchasable)
    }
}
