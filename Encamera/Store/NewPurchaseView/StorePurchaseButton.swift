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
    let selectedPurchasable: Binding<(any PurchaseOptionComponentProtocol)?>
    let onPurchase: (any PurchaseOptionComponentProtocol) -> Void

    init(
        selectedPurchasable: Binding<(any PurchaseOptionComponentProtocol)?>,
        isSubscribedToSelectedSubscription: Binding<Bool>,
        onPurchase: @escaping (any PurchaseOptionComponentProtocol) -> Void
    ) {
        self._isSubscribedToSelectedSubscription = isSubscribedToSelectedSubscription
        self.selectedPurchasable = selectedPurchasable
        self.onPurchase = onPurchase
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if let selectedPurchasable = selectedPurchasable.wrappedValue {
                    onPurchase(selectedPurchasable)
                }
            } label: {
                Group {
                    if let selectedPurchasable = selectedPurchasable.wrappedValue {
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
            .primaryButton(enabled: selectedPurchasable.wrappedValue != nil && !isSubscribedToSelectedSubscription)
            .disabled(selectedPurchasable.wrappedValue == nil || isSubscribedToSelectedSubscription)

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
