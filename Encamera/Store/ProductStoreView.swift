//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI
import EncameraCore

typealias PurchaseResultAction = ((PurchaseFinishedAction) -> Void)

class ProductStoreViewViewModel: ObservableObject {

    @Published var purchaseOptions: [any PurchaseOptionComponentProtocol] = [
        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month", savingsPercentage: 0.17),
        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year", savingsPercentage: nil),
        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time", savingsPercentage: nil)
    ]

}

struct ProductStoreView: View {


    @State private var selectedPurchasable: (any Purchasable)?
    @State private var currentActiveSubscription: ServiceSubscription?
    @State private var errorAlertIsPresented = false
    @State private var showPostPurchaseScreen = false
    @StateObject var viewModel: ProductStoreViewViewModel = .init()
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
                PurchaseStorefront(purchaseOptions: viewModel.purchaseOptions, selectedPurchasable: viewModel.purchaseOptions[1]) { purchasable in


//                    Task(priority: .userInitiated) { @MainActor in
//                        var action: PurchaseFinishedAction
//                        switch action {
//                        case .purchaseComplete(let price, let currencyCode):
//                            NotificationManager.cancelNotificationForPremiumReminder()
//                            showPostPurchaseScreen = true
//                            EventTracking.trackPurchaseCompleted(
//                                from: fromView,
//                                currency: currencyCode,
//                                amount: price,
//                                product: purchasable.id)
//                        case .displayError:
//                            errorAlertIsPresented = true
//                            EventTracking.trackPurchaseIncomplete(from: fromView, product: purchasable.id)
//                        case .noAction:
//                            EventTracking.trackPurchaseIncomplete(from: fromView, product: purchasable.id)
//                        case .cancelled:
//                            EventTracking.trackPurchaseCancelled(from: fromView, product: purchasable.id)
//
//                        case .pending:
//                            EventTracking.trackPurcasePending(from: fromView, product: purchasable.id)
//                        }
//                        purchaseAction?(action)
//
//                    }
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
//                    selectedPurchasable = subscriptionController.entitledSubscription ?? subscriptionController.subscriptions.first
//                    currentActiveSubscription = subscriptionController.entitledSubscription

                }
//                .alert(
//                    subscriptionController.purchaseError?.errorDescription ?? "",
//                    isPresented: $errorAlertIsPresented,
//                    actions: {}
//                )

            }.onAppear {
                EventTracking.trackShowPurchaseScreen(from: fromView)
            }
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
