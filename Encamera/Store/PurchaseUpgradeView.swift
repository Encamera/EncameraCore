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

struct FeatureIcon: View {
    let image: Image

    var body: some View {
        ZStack {
            Rectangle()
                .foregroundColor(.clear)
                .frame(width: 42, height: 42)
                .background(Color.white)
                .cornerRadius(4)
                .opacity(0.10)
            image
                .opacity(0.50)
        }
        .frame(width: 42, height: 42)
    }
}

struct FeatureText: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: subtitle != nil ? 4 : nil) {
            Group {
                Text(title)
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.white)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Font.custom("Satoshi Variable", size: 14))
                        .foregroundColor(.white)
                        .opacity(0.80)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)

        }.frame(height: 50)
            .transition(.move(edge: .bottom))
    }
}

func createFeatureRow(image: Image, title: String, subtitle: String? = nil) -> some View {
    return HStack(alignment: .center, spacing: 12) {
        FeatureIcon(image: image)
        FeatureText(title: title, subtitle: subtitle)
    }
}




struct PurchaseUpgradeView: View {


    @ObservedObject var subscriptionController: StoreSubscriptionController = StoreActor.shared.subscriptionController
    @ObservedObject var productController: StoreProductController = StoreActor.shared.productController
    @State private var selectedSubscription: ServiceSubscription?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    @State private var showTweetForFreeView = false

    @Environment(\.dismiss) private var dismiss

    var showDismissButton = true
    var fromView: String
    var purchaseAction: ((PurchaseFinishedAction) -> Void)?

    var body: some View {
        ZStack(alignment: .top) {

            VStack(spacing: 8) {
                PurchaseUpgradeHeaderView()
                    .frame(maxWidth: .infinity)
                createFeatureRow(image: Image("Premium-Infinity"), title: "Unlimited Albums")
                createFeatureRow(image: Image("Premium-Albums"), title: "Unlimited Photos")
                createFeatureRow(image: Image("Premium-Folders"), title: "Password Protected Albums")
                createFeatureRow(image: Image("Premium-CustomIcon"), title: "Custom Icon")
                Spacer()
            }
            .padding()
            .navigationBarTitle(L10n.upgradeToday)
            .overlay(alignment: .topTrailing) {
                if showDismissButton {
                    dismissButton
                        .padding()
                }
            }
            .background(Color.background)
            .onAppear {
                selectedSubscription = subscriptionController.entitledSubscription ?? subscriptionController.subscriptions.first
                currentActiveSubscription = subscriptionController.entitledSubscription
            }
            .alert(
                subscriptionController.purchaseError?.errorDescription ?? "",
                isPresented: $errorAlertIsPresented,
                actions: {}
            )
            productCellsScrollView
        }.onAppear {
            EventTracking.trackShowPurchaseScreen(from: fromView)
        }
    }

    var dismissButton: some View {
        Button {
            dismiss()
            EventTracking.trackPurchaseScreenDismissed(from: fromView)
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


    @ViewBuilder
    var productCellsScrollView: some View {
        VStack {
            Spacer()
            let subscriptions = subscriptionController.subscriptions
            let products = productController.products
            PurchaseUpgradeOptionsListView(
                subscriptions: subscriptions,
                products: products,
                purchasedProducts: productController.purchasedProducts,
                selectedOption: $selectedSubscription,
                currentActiveSubscription: currentActiveSubscription,
                freeUnlimitedTapped: {
                    self.showTweetForFreeView = true
                },
                onPurchase: {
                    if let subscription = selectedSubscription {

                        Task(priority: .userInitiated) { @MainActor in
                            let action = await subscriptionController.purchase(option: subscription)
                            switch action {
                            case .purchaseComplete(let price, let currencyCode):
                                EventTracking.trackPurchaseCompleted(
                                    from: fromView,
                                    currency: currencyCode,
                                    amount: price,
                                    product: subscription.product.id)
                                dismiss()
                            case .displayError: errorAlertIsPresented = true
                                EventTracking.trackPurchaseIncomplete(from: fromView)
                            case .noAction: 
                                EventTracking.trackPurchaseIncomplete(from: fromView)
                                break
                            }
                            purchaseAction?(action)
                        }
                    }
                }
            )
            .padding(.top)
        }
    }
}

struct PurchaseUpgradeView_Previews: PreviewProvider {

    static var previews: some View {
        ProductStoreView(fromView: "Preview")
            .preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
    }

}
