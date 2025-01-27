//
//  PurchaseButton.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.25.
//

import SwiftUI
import EncameraCore


struct StorePurchaseButton: View {

    @Binding var isSubscribedToSelectedSubscription: Bool
    @Binding var selectedPurchasable: (any PremiumPurchasable)?
    let onPurchase: (any PremiumPurchasable) -> Void

    init(
        selectedPurchasable: Binding<(any PremiumPurchasable)?>,
        isSubscribedToSelectedSubscription: Binding<Bool>,
        onPurchase: @escaping (any PremiumPurchasable) -> Void
    ) {
        self._isSubscribedToSelectedSubscription = isSubscribedToSelectedSubscription
        self._selectedPurchasable = selectedPurchasable
        self.onPurchase = onPurchase
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if let selectedPurchasable = selectedPurchasable {
                    onPurchase(selectedPurchasable)
                }
            } label: {
                Group {
                    if let selectedPurchasable = selectedPurchasable {
                        if selectedPurchasable.isEligibleForIntroOffer {
                            VStack {
                                Text(L10n.startTrialOffer)
                                Text(AppConstants.isInPromoMode ? L10n.promoFreeTrialTerms(selectedPurchasable.formattedPrice) : L10n.freeTrialTerms(selectedPurchasable.formattedPrice))
                                    .fontType(.pt12, on: .primaryButton)
                            }
                        } else if isSubscribedToSelectedSubscription {
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
            .primaryButton(enabled: selectedPurchasable != nil && !isSubscribedToSelectedSubscription)
            .disabled(selectedPurchasable == nil || isSubscribedToSelectedSubscription)

            Spacer().frame(height: 8)
            Text(L10n.noCommitmentCancelAnytime)
                .fontType(.pt14, weight: .bold)
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}


//// Preview for testing
//struct StorePurchaseButton_Previews: PreviewProvider {
//    @State static var canRedeemIntroOffer = true
//    @State static var redeemSheetIsPresented = false
//    @State static var isSubscribedToSelectedSubscription = false
//
//    static var previews: some View {
//        StorePurchaseButton(
//            selectedPurchasable: MockPurchasable(),
//            canRedeemIntroOffer: $canRedeemIntroOffer,
//            redeemSheetIsPresented: $redeemSheetIsPresented,
//            isSubscribedToSelectedSubscription: $isSubscribedToSelectedSubscription
//        ) {
//            print("Purchase initiated")
//        }
//    }
//}
