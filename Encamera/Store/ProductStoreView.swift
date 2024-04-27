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
                .renderingMode(.template)
//                .opacity(0.50)
                .foregroundColor(.actionYellowGreen)
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




typealias PurchaseResultAction = ((PurchaseFinishedAction) -> Void)

struct ProductStoreView: View {


    @ObservedObject var subscriptionController: StoreSubscriptionController = StoreActor.shared.subscriptionController
    @ObservedObject var productController: StoreProductController = StoreActor.shared.productController
    @State private var selectedPurchasable: (any Purchasable)?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    @State private var showPostPurchaseScreen = false

    @Environment(\.presentationMode) private var presentationMode



    var showDismissButton = true
    var fromView: String
    var purchaseAction: PurchaseResultAction?

    var body: some View {
        Group {
            if showPostPurchaseScreen {
                PostPurchaseView()
            } else {
                purchaseScreen
            }
        }.transition(.scale)
    }

    var dismissButton: some View {
        DismissButton {
            dismiss()
            EventTracking.trackPurchaseScreenDismissed(from: fromView)
        }
    }

    private var purchaseScreen: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Image("Premium-TopHalo")
                    .resizable()

                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width)
                    .ignoresSafeArea(.all)
                ScrollView {
                    VStack(spacing: 0) {
                        PurchaseUpgradeHeaderView(purchasedProduct: productController.purchasedProduct)
                            .frame(maxWidth: .infinity)
                        if productController.purchasedProduct == nil {
                            productCellsScrollView
                        }
                        Spacer()
                    }
                }
                .scrollIndicators(.never)
                .navigationBarTitle(L10n.upgradeToday)
                .overlay(alignment: .topLeading) {
                    if showDismissButton {
                        dismissButton
                            .padding()
                    }
                }
                .onAppear {
                    selectedPurchasable = subscriptionController.entitledSubscription ?? subscriptionController.subscriptions.first
                    currentActiveSubscription = subscriptionController.entitledSubscription
                }
                .alert(
                    subscriptionController.purchaseError?.errorDescription ?? "",
                    isPresented: $errorAlertIsPresented,
                    actions: {}
                )

            }.onAppear {
                EventTracking.trackShowPurchaseScreen(from: fromView)
            }
        }
    }

    private func createFeatureRow(image: Image, title: String, subtitle: String? = nil) -> some View {
        return HStack(alignment: .center, spacing: 12) {
            FeatureIcon(image: image)
            FeatureText(title: title, subtitle: subtitle)
        }
    }

    @ViewBuilder
    var productCellsScrollView: some View {

        VStack {
            Spacer()
            let subscriptionOptions = subscriptionController.subscriptions
            let oneTimePurchaseOptions = productController.products
            PurchaseUpgradeOptionsListView(
                subscriptionOptions: subscriptionOptions,
                oneTimePurchaseOptions: oneTimePurchaseOptions,
                purchasedProduct: productController.purchasedProduct,
                selectedOption: $selectedPurchasable,
                currentActiveSubscription: currentActiveSubscription,
                onPurchase: {
                    guard let subscription = selectedPurchasable else {
                        return
                    }

                        Task(priority: .userInitiated) { @MainActor in
                            var action: PurchaseFinishedAction
                            if let subscription = subscription as? ServiceSubscription {
                                action = await subscriptionController.purchase(option: subscription)
                            } else if let product = subscription as? OneTimePurchase {
                                action = await productController.purchase(product: product)
                            } else {
                                print("Unknown purchasable type")
                                return
                            }
                            switch action {
                            case .purchaseComplete(let price, let currencyCode):
                                showPostPurchaseScreen = true
                                EventTracking.trackPurchaseCompleted(
                                    from: fromView,
                                    currency: currencyCode,
                                    amount: price,
                                    product: subscription.product.id)
                            case .displayError: errorAlertIsPresented = true
                                EventTracking.trackPurchaseIncomplete(from: fromView)
                            case .noAction:
                                EventTracking.trackPurchaseIncomplete(from: fromView)
                                break
                            }
                            purchaseAction?(action)

                    }
                }
            )

            .padding(.top)
        }

    }


    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

struct PurchaseUpgradeView_Previews: PreviewProvider {

    static var previews: some View {
        ProductStoreView(fromView: "Preview")
            .preferredColorScheme(.dark)
            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
    }

}
