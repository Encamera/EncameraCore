//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI



struct SubscriptionStoreView: View {
    @ObservedObject var controller: StoreSubscriptionController
    @State private var selectedSubscription: ServiceSubscription?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    var showDismissButton = true
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            SubscriptionStoreHeaderView()
                .frame(maxWidth: .infinity)
            subscriptionCellsView
        }
        .overlay(alignment: .topTrailing) {
            if showDismissButton {
                dismissButton
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            subscriptionPurchaseView
        }
        .background(Color.background)
        .onAppear {
            selectedSubscription = controller.entitledSubscription
            currentActiveSubscription = controller.entitledSubscription
        }
        .alert(
            controller.purchaseError?.errorDescription ?? "",
            isPresented: $errorAlertIsPresented,
            actions: {}
        )
    }
    
    var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    .secondary,
                    .clear,
                    Color(uiColor: .systemGray5)
                )
        }
        .buttonStyle(.borderless)
        .opacity(0.8)
        .font(.title)
    }
    
    var subscriptionPurchaseView: some View {
        SubscriptionPurchaseView(selectedSubscription: selectedSubscription) {
            if let subscription = selectedSubscription {
                Task(priority: .userInitiated) { @MainActor in
                    let action = await controller.purchase(option: subscription)
                    switch action {
                    case .dismissStore: dismiss()
                    case .displayError: errorAlertIsPresented = true
                    case .noAction: break
                    }
                }
            }
        }
    }
    
    var subscriptionCellsView: some View {
        ScrollView(.vertical) {
            if let subscriptions = controller.subscriptions {
                SubscriptionStoreOptionsView(
                    subscriptions: subscriptions,
                    selectedOption: $selectedSubscription,
                    currentActiveSubscription: currentActiveSubscription
                )
                .padding(.top)
            }
        }
    }
}
     
struct SubscriptionStoreHeaderView: View {
    
    var body: some View {
        VStack(spacing: 5) {
            Image("EncameraPremiumHeader")
            Group {
                Text("View unlimited photos for each key.")
                Text("Create an unlimited number of keys.")
                Text("Support privacy-focused development.")
            }
            .fontType(.small)
        }
        .padding(.top, 0)
        .padding(.bottom, 30)
    }
}

struct SubscriptionStoreOptionsView: View {
    let subscriptions: [ServiceSubscription]
    @Binding var selectedOption: ServiceSubscription?
    let currentActiveSubscription: ServiceSubscription?
    
    func binding(for subscription: ServiceSubscription) -> Binding<Bool> {
        return Binding {
            selectedOption?.id == subscription.id
        } set: { newValue in
            selectedOption = newValue ? subscription : nil
        }
    }
    
    var body: some View {
        VStack {
            ForEach(subscriptions) { subscription in
                subscriptionOptionCell(for: subscription)
            }
        }
    }

    func subscriptionOptionCell(for subscription: ServiceSubscription) -> some View {
        var savingsInfo: SubscriptionSavings?
        if subscription.id == StoreActor.unlimitedYearlyID {
            savingsInfo = self.savings()
        }
        return SubscriptionOptionView(
            subscription: subscription,
            savings: savingsInfo,
            isSubscribed: currentActiveSubscription?.id == subscription.id,
            isOn: binding(for: subscription)
        )
    }
    
    func savings() -> SubscriptionSavings? {
        guard let yearlySubscription = subscriptions.first(where: { $0.id == StoreActor.unlimitedYearlyID }) else {
            return nil
        }
        guard let monthlySubscription = subscriptions.first(where: { $0.id == StoreActor.unlimitedMonthlyID }) else {
            return nil
        }
        
        let yearlyPriceForMonthlySubscription = 12 * monthlySubscription.price
        let amountSaved = yearlyPriceForMonthlySubscription - yearlySubscription.price
        
        guard amountSaved > 0 else {
            return nil
        }
        
        let percentSaved = amountSaved / yearlyPriceForMonthlySubscription
        let monthlyPrice = yearlySubscription.price / 12
        
        return SubscriptionSavings(percentSavings: percentSaved, granularPrice: monthlyPrice, granularPricePeriod: .month)
    }
}


struct SubscriptionPurchaseView: View {
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
                        Text("Start trial offer")
                    } else {
                        Text("Subscribe")
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity)
            }
            .primaryButton(on: .elevated)
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

struct SubscriptionStoreView_Previews: PreviewProvider {
    
    static var previews: some View {
        SubscriptionStoreView(
            controller: StoreActor.shared.subscriptionController
        ).preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
    }
    
}
