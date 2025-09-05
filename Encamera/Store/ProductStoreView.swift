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

extension Offering: PremiumPurchasableCollection {
    var options: [any PremiumPurchasable] {
        return availablePackages
    }

    var defaultSelection: (any PremiumPurchasable)? {
        let monthlySubscription = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year })
        return monthlySubscription
    }

    func yearlySavings() -> SubscriptionSavings? {

        guard let yearlySubscription = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .year }) else {
            return nil
        }
        guard let monthlySubscription = availablePackages.first(where: { $0.storeProduct.subscriptionPeriod?.unit == .month }) else {
            return nil
        }

        let yearlyPriceForMonthlySubscription = 12 * monthlySubscription.storeProduct.price
        let amountSaved = yearlyPriceForMonthlySubscription - yearlySubscription.storeProduct.price

        guard amountSaved > 0 else {
            return nil
        }

        let monthlyPrice = yearlySubscription.storeProduct.price / 12
        guard let yearlyStorekitProduct = yearlySubscription.storeProduct.sk2Product else {
            return nil
        }
        return SubscriptionSavings(totalSavings: amountSaved,
                                   granularPrice: monthlyPrice,
                                   granularPricePeriod: .month,
                                   priceFormatStyle: yearlyStorekitProduct.priceFormatStyle,
                                   subscriptionPeriodUnitFormatStyle: yearlyStorekitProduct.subscriptionPeriodUnitFormatStyle)
    }
}

extension Package: PremiumPurchasable {

    var id: String {
        return storeProduct.productIdentifier
    }

    var optionPeriod: String {
        return storeProduct.localizedTitle
    }

    // Returns the display price of the product
    var formattedPrice: String {
        guard let product = self.storeProduct.sk2Product else {
            return ""
        }
        return product.displayPrice
    }

    // This should return "per month", "per year", or "one time"
    var billingFrequency: String {
        guard let product = self.storeProduct.sk2Product else {
            return ""
        }

        if product.type == .autoRenewable {
            if let subscriptionPeriod = product.subscription?.subscriptionPeriod {
                switch subscriptionPeriod.unit {
                case .month:
                    return "per month"
                case .year:
                    return "per year"
                default:
                    return ""
                }
            }
        } else if product.type == .nonConsumable {
            return "one time"
        }

        return ""
    }


    // Text for purchase action
    var purchaseActionText: String {
        return "Purchase"
    }

    // Eligibility for introductory offers
    var isEligibleForIntroOffer: Bool {
        guard let product = self.storeProduct.sk2Product else {
            return false
        }
        return product.subscription?.introductoryOffer != nil
    }
    var isLifetime: Bool {
        guard let product = self.storeProduct.sk2Product else {
            return false
        }
        return product.type == .nonConsumable
    }
}

// Helper extension to round Decimal values
private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var roundedValue = Decimal()
        NSDecimalRound(&roundedValue, &value, scale, .plain)
        return roundedValue
    }
}

typealias PurchaseResultAction = ((PurchaseFinishedAction) -> Void)

class ProductStoreViewViewModel: ObservableObject {

    @MainActor
    @Published var purchaseOptions: PremiumPurchasableCollection?

    var purchasedPermissionsManaging: PurchasedPermissionManaging

    init(purchasedPermissionsManaging: PurchasedPermissionManaging) {
        self.purchasedPermissionsManaging = purchasedPermissionsManaging
    }

    func loadOffering() async throws {
        let offerings = try await Purchases.shared.offerings()

        Task { @MainActor in
            self.purchaseOptions = offerings.current
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
                    PurchaseStorefront(purchaseOptions: options, selectedPurchasable: options.defaultSelection) { purchasable in


                       Task(priority: .userInitiated) { @MainActor in
                            guard let purchasable = purchasable as? Package else {
                                return
                            }
                           do {
                               let (transaction, customerInfo, userCancelled) = try await Purchases.shared.purchase(package: purchasable)
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
            }.onAppear {
                EventTracking.trackShowPurchaseScreen(from: fromView)
            }.task {
                try? await viewModel.loadOffering()
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
