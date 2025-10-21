//
//  SubscriptionView.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import SwiftUI
import EncameraCore
import RevenueCat

typealias PurchaseResultAction = ((PurchaseFinishedAction) -> Void)

class ProductStoreViewViewModel: ObservableObject {

    @MainActor
    @Published var purchaseOptions: PremiumPurchasableCollection?

    var purchasedPermissionsManaging: PurchasedPermissionManaging

    init(purchasedPermissionsManaging: PurchasedPermissionManaging) {
        self.purchasedPermissionsManaging = purchasedPermissionsManaging
    }

    func loadOffering() async throws {
        let offerings = try await RevenueCat.Purchases.shared.offerings()

        Task { @MainActor in
            self.purchaseOptions = offerings.offering(identifier: "DefaultOfferingWithLifetimeOptions")
        }
    }
}

struct ProductStoreView: View {


    @State private var selectedPurchasable: (any Purchasable)?
    @State private var errorAlertIsPresented = false
    @State private var showPostPurchaseScreen = false
    @EnvironmentObject var appModalStateModel: AppModalStateModel




    var showDismissButton = true
    var fromView: String
    var purchaseAction: PurchaseResultAction?
    @StateObject var viewModel: ProductStoreViewViewModel


    var body: some View {
        Group {
            if showPostPurchaseScreen {
                PostPurchaseView()
            } else {
                purchaseScreen
            }
        }.transition(.opacity)
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
                if let options = viewModel.purchaseOptions {
                    purchaseOptionScreen(options: options)
                } else {
                    ZStack {
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gradientBackground()
                }
            }.onAppear {
                EventTracking.trackShowPurchaseScreen(from: fromView)
            }.task {
                try? await viewModel.loadOffering()
            }
        }
    }

    private func purchaseOptionScreen(options: PremiumPurchasableCollection) -> some View {
        PurchaseStorefront(purchaseOptions: options, selectedPurchasable: options.defaultSelection) { purchasable in


           Task(priority: .userInitiated) { @MainActor in
               guard let purchasable = purchasable as? RevenueCat.Package else {
                    return
                }
               do {
                   let (transaction, customerInfo, userCancelled) = try await RevenueCat.Purchases.shared.purchase(package: purchasable)
                   if !customerInfo.entitlements.active.isEmpty {
                       if let skTransaction = transaction?.sk2Transaction,
                           let amount = purchasable.storeProduct.sk2Product?.price,
                          let currency = purchasable.storeProduct.sk2Product?.priceFormatStyle.currencyCode {
                           let product = skTransaction.productID
                           EventTracking.trackPurchaseCompleted(from: fromView, currency: currency, amount: amount, product: product)
                       }

                       showPostPurchaseScreen = true
                       Task{
                           if let appPermissions = viewModel.purchasedPermissionsManaging as? AppPurchasedPermissionUtils {
                               await appPermissions.refreshEntitlements()
                           }
                       }
                       purchaseAction?(.purchaseComplete(amount: purchasable.storeProduct.price, currencyCode: purchasable.storeProduct.localizedPriceString))

                   }

                   if userCancelled {
                       EventTracking.trackPurchaseCancelled(from: fromView, product: purchasable.id)
                       purchaseAction?(.cancelled)
                   }

               } catch {
                   errorAlertIsPresented = true
                   EventTracking.trackPurchaseIncomplete(from: fromView, product: purchasable.id)
               }
            }
        }
        .scrollIndicators(.never)
        .navigationBarTitle(L10n.upgradeToday)
        .transition(.opacity)
        .overlay(alignment: .topLeading) {
            if showDismissButton {
                dismissButton
                    .padding()
            }
        }
    }

    private func dismiss() {
        appModalStateModel.currentModal = nil
    }
}

//struct PurchaseUpgradeView_Previews: PreviewProvider {
//
//    static var previews: some View {
//        ProductStoreView(fromView: "Preview", viewModel: .init(purchasedPermissionsManaging: DemoPurchasedPermissionManaging())))
//            .preferredColorScheme(.dark)
//            .previewDevice(PreviewDevice(rawValue: "iPhone 8"))
//    }
//
//}
