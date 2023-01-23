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

typealias ProductStoreView = PurchaseUpgradeView


struct PurchaseUpgradeView: View {
    @ObservedObject var subscriptionController: StoreSubscriptionController = StoreActor.shared.subscriptionController
    @ObservedObject var productController: StoreProductController = StoreActor.shared.productController
    @State private var selectedSubscription: ServiceSubscription?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    var showDismissButton = true
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            PurchaseUpgradeHeaderView()
                .frame(maxWidth: .infinity)
            productCellsScrollView
        }
        .overlay(alignment: .topTrailing) {
            if showDismissButton {
                dismissButton
                    .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSubscription != nil {
                subscriptionPurchaseView
            }
        }
        .background(Color.background)
        .onAppear {
            selectedSubscription = subscriptionController.entitledSubscription
            currentActiveSubscription = subscriptionController.entitledSubscription
        }
        .alert(
            subscriptionController.purchaseError?.errorDescription ?? "",
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
                    let action = await subscriptionController.purchase(option: subscription)
                    switch action {
                    case .dismissStore: dismiss()
                    case .displayError: errorAlertIsPresented = true
                    case .noAction: break
                    }
                }
            }
        }
    }
    
    var productCellsScrollView: some View {
        ScrollView(.vertical) {
            if let subscriptions = subscriptionController.subscriptions,
               let products = productController.products {
                PurchaseUpgradeOptionsListView(
                    subscriptions: subscriptions,
                    products: products,
                    purchasedProducts: productController.purchasedProducts,
                    selectedOption: $selectedSubscription,
                    currentActiveSubscription: currentActiveSubscription
                )
                .padding(.top)
            }
        }
    }
}


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

struct PurchaseUpgradeView_Previews: PreviewProvider {
    
    static var previews: some View {
        ProductStoreView()
            .preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
    }
    
}
