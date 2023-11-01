//
//  SubscriptionPurchaseButton.swift
//  Encamera
//
//  Created by Alexander Freas on 30.10.23.
//

import SwiftUI
import EncameraCore
import StoreKit

struct SubscriptionPurchaseButton: View {
    @State private var canRedeemIntroOffer = false
    @State private var redeemSheetIsPresented = false

    @Environment(\.dismiss) private var dismiss

    let selectedSubscription: ServiceSubscription?
    let onPurchase: () -> Void

    var body: some View {
        VStack {
            Button {
                onPurchase()
            } label: {
                Group {
                    if canRedeemIntroOffer {
                        Text(L10n.startTrialOffer)
                    } else {
                        Text(L10n.subscribe)
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity)
            }

            .primaryButton(on: .darkBackground)
            .disabled(selectedSubscription == nil)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .onChange(of: selectedSubscription) { newValue in

            guard let selectedSubscription = newValue?.subscriptionInfo else {
                return
            }
            Task(priority: .utility) { @MainActor in
                canRedeemIntroOffer = await selectedSubscription.isEligibleForIntroOffer && selectedSubscription.introductoryOffer != nil
            }
        }
    }

}

#Preview {
    VStack {
        if let sub = StoreActor.shared.subscriptionController.subscriptions.first {
            let _ = print(sub)
            SubscriptionPurchaseButton(selectedSubscription: sub) {

            }
        } else {
            EmptyView()
        }
    }
}
