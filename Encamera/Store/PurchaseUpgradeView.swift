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
    @State private var selectedSubscription: ServiceSubscription?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    @State private var showTweetForFreeView = false

    @Environment(\.presentationMode) private var presentationMode



    var showDismissButton = true
    var fromView: String
    var purchaseAction: PurchaseResultAction?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Image("Premium-TopHalo")
                    .resizable()

                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width)
                    .ignoresSafeArea(.all)
                ScrollView {
                    VStack(spacing: 0) {
                        PurchaseUpgradeHeaderView()
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 0) {

                            createFeatureRow(image: Image("Premium-Albums"), title: L10n.unlimitedStorageFeatureRowTitle)
                            createFeatureRow(image: Image("Premium-Infinity"), title: L10n.unlimitedAlbumsFeatureRowTitle)
                            createFeatureRow(image: Image("Premium-Folders"), title: L10n.iCloudStorageFeatureRowTitle)
                        }.padding(.leading, 40)
                        Spacer()
                    }
                }

                .navigationBarTitle(L10n.upgradeToday)
                .overlay(alignment: .topLeading) {
                    if showDismissButton {
                        dismissButton
                            .padding()
                    }
                }
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
    }

    var dismissButton: some View {
        DismissButton {
            dismiss()
            EventTracking.trackPurchaseScreenDismissed(from: fromView)
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
