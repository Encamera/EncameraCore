//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI
import StoreKit


struct ProductStoreView: View {
    @ObservedObject var controller: StoreProductController
    @State private var selectedSubscription: ServiceSubscription?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    var showDismissButton = true
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            ProductStoreHeaderView()
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
            productPurchaseView
        }
        .background(Color.background)
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
    
    var productPurchaseView: some View {
        ProductPurchaseView(selectedSubscription: selectedSubscription) {
            Task(priority: .userInitiated) { @MainActor in
                let action = await controller.purchase()
                switch action {
                case .dismissStore: dismiss()
                case .displayError: errorAlertIsPresented = true
                case .noAction: break
                }
            }
            
        }
    }
    
    var subscriptionCellsView: some View {
        ScrollView(.vertical) {
            if let product = controller.product {
                ProductStoreOptionsView(
                    products: [product],
                    purchasedProducts: controller.isEntitled ? [product] : []
                )
                .padding(.top)
            }
        }
    }
}
     
struct ProductStoreHeaderView: View {
    
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

struct ProductStoreOptionsView: View {
    let products: [OneTimePurchase]
    let purchasedProducts: [OneTimePurchase]
    
    
    
    var body: some View {
        VStack {
            ForEach(products) { product in
                productCell(for: product)
            }
        }.padding(.horizontal)
            
    }

    func productCell(for product: OneTimePurchase) -> some View {
        let hasPurchased = purchasedProducts.contains(product)
            return ProductOptionView(
            product: product, isPurchased: hasPurchased
        )
    }
}


struct ProductPurchaseView: View {
    @State private var canRedeemIntroOffer = false
    @State private var redeemSheetIsPresented = false
    
    @Environment(\.dismiss) private var dismiss
    
    let selectedSubscription: ServiceSubscription?
    let onPurchase: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
                Button {
                    Task(priority: .userInitiated) {
                        await StoreActor.shared.presentCodeRedemptionSheet()
                    }
                } label: {
                    Text("Enter Promo Code")
                     .foregroundColor(.foregroundPrimary)
                     .frame(maxWidth: .infinity)

                }
            Button {
                Task(priority: .userInitiated) {
                    try await AppStore.sync()
                }
            } label: {
                   Text("Restore Purchases")
                    .foregroundColor(.foregroundPrimary)
                    .frame(maxWidth: .infinity)
            }
        }
        
        .padding(.horizontal)

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

struct ProductStoreView_Previews: PreviewProvider {
    
    static var previews: some View {
        ProductStoreView(
            controller: StoreActor.shared.productController
        ).preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
    }
    
}
