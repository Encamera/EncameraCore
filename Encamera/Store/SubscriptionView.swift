//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI
import StoreKit
import EncameraCore



struct SubscriptionPurchaseButton: View {

    
    var subscriptionController: StoreSubscriptionController = StoreActor.shared.subscriptionController
    @State private var canRedeemIntroOffer = true
    @State private var redeemSheetIsPresented = false
    
    @Environment(\.dismiss) private var dismiss
    
    let selectedSubscription: ServiceSubscription?
    let onPurchase: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            Button {
                onPurchase()
            } label: {
                Group {
                    if canRedeemIntroOffer, let selectedSubscription
                    {
                        VStack {
                            Text(L10n.startTrialOffer)
                            Text(L10n.freeTrialTerms(selectedSubscription.priceText))
                                .fontType(.pt12, on: .primaryButton)
                        }
                    } else if subscriptionController.entitledSubscription == selectedSubscription {
                        Text(L10n.subscribed)
                    } else {
                        Text(L10n.subscribe)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .primaryButton(enabled: !subscribedToSelectedSubscription)
            .disabled(selectedSubscription == nil || subscribedToSelectedSubscription)

            Spacer().frame(height: 8)
            Text(L10n.noCommitmentCancelAnytime)
                .fontType(.pt14, weight: .bold)
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: selectedSubscription) { newValue in
            
            guard let selectedSubscription = newValue?.subscriptionInfo else {
                return
            }
            Task(priority: .utility) { @MainActor in
                canRedeemIntroOffer = await selectedSubscription.isEligibleForIntroOffer && selectedSubscription.introductoryOffer != nil
            }
        }
    }

    @MainActor
    private var subscribedToSelectedSubscription: Bool {
        return subscriptionController.entitledSubscription == selectedSubscription
    }
}

#Preview {
    SubscriptionPurchaseButton(selectedSubscription: nil, onPurchase: {})
}
