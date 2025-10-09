//
//  PurchaseStorefront.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.25.
//

import SwiftUI
import EncameraCore
import RevenueCat

enum PurchaseType: String, CaseIterable {
    case subscriptions = "Subscriptions"
    case oneTime = "One-time payment"
}

struct PurchaseStorefront: View {
    @State var currentSubscription: (any PremiumPurchasable)?
    var purchaseOptions: PremiumPurchasableCollection
    @State var selectedPurchasable: (any PremiumPurchasable)?
    @State private var selectedPurchaseType: PurchaseType = .subscriptions
    var onPurchase: ((any PremiumPurchasable) -> Void)
    
    // Computed properties to filter purchase options
    private var subscriptionOptions: [any PremiumPurchasable] {
        purchaseOptions.options.filter { !$0.isLifetime }
    }
    
    private var oneTimeOptions: [any PremiumPurchasable] {
        purchaseOptions.options.filter { $0.isLifetime }
    }
    
    private var currentOptions: [any PremiumPurchasable] {
        selectedPurchaseType == .subscriptions ? subscriptionOptions : oneTimeOptions
    }

    private func loadEntitlement() async  {
        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            let filteredSubs = purchaseOptions.options.filter { option in
                customerInfo.entitlements.all.contains { (key: String, value: EntitlementInfo) in
                    return value.productIdentifier == option.id
                }
            }
            let sub = filteredSubs.sorted(by: {$0.isLifetime && !$1.isLifetime}).first
            currentSubscription = sub
        } catch {
        }

    }

    var showPurchaseOptions: Bool {
        if let currentSubscription {
            return currentSubscription.isLifetime == false
        }
        return true
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Image(AppConstants.isInPromoMode ? "HalloweenBG" : "Premium-TopHalo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width)
                    .ignoresSafeArea(.all)

                VStack {
                    ScrollView(showsIndicators: false) {
                        PurchaseUpgradeHeaderView(purchasedProduct: currentSubscription)
                        if showPurchaseOptions {
                            // Segmented control for purchase type
                            if !subscriptionOptions.isEmpty && !oneTimeOptions.isEmpty {
                                Picker("Purchase Type", selection: $selectedPurchaseType) {
                                    ForEach(PurchaseType.allCases, id: \.self) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal)
                                .onChange(of: selectedPurchaseType) { _, newType in
                                    // Auto-select first item in the new list
                                    selectedPurchasable = currentOptions.first
                                }
                            }
                            
                            // Purchase options with sliding transition
                            Group {
                                PurchaseOptionComponent(
                                    viewModel: .init(optionsCollection: FilteredPurchaseOptions(
                                        options: currentOptions,
                                        originalCollection: purchaseOptions
                                    )),
                                    selectedOption: $selectedPurchasable,
                                    defaultOption: selectedPurchasable
                                )
                                .padding()
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: selectedPurchaseType == .oneTime ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: selectedPurchaseType == .subscriptions ? .leading : .trailing).combined(with: .opacity)
                            ))
                            .animation(.easeInOut(duration: 0.3), value: selectedPurchaseType)
                            .id(selectedPurchaseType) // Force view recreation on type change
                        }
                        PremiumBenefitsScrollView(isPremium: Binding<Bool> {
                            return currentSubscription != nil
                        } set: { _ in
                        })
                    }
                    if showPurchaseOptions {
                        StorePurchaseButton(selectedPurchasable: $selectedPurchasable,
                                            activePurchase: $currentSubscription,
                                            onPurchase: onPurchase)
                        .padding()
                    }
                }.frame(maxWidth: 600)
            }
            .onAppear {
                // Select the default based on the current purchase type
                selectedPurchasable = currentOptions.first ?? purchaseOptions.defaultSelection
            }
            .task {
                await loadEntitlement()
            }
        }
    }
}

// Helper struct to wrap filtered options while preserving original collection's functionality
struct FilteredPurchaseOptions: PremiumPurchasableCollection {
    var options: [any PremiumPurchasable]
    var originalCollection: PremiumPurchasableCollection
    
    var defaultSelection: (any PremiumPurchasable)? {
        return options.first
    }
    
    func yearlySavings() -> SubscriptionSavings? {
        // Only return savings if we're showing subscriptions
        if options.allSatisfy({ !$0.isLifetime }) {
            return originalCollection.yearlySavings()
        }
        return nil
    }
}

//
#Preview {
    PurchaseStorefront(purchaseOptions: PurchaseOptionCollectionModel(options: [
        PurchaseOptionComponentModel(optionPeriod: "1 Month", formattedPrice: "$4.99", billingFrequency: "per month", isLifetime: false),
        PurchaseOptionComponentModel(optionPeriod: "1 Year", formattedPrice: "$49.99", billingFrequency: "per year", isLifetime: false),
        PurchaseOptionComponentModel(optionPeriod: "Lifetime", formattedPrice: "$99.99", billingFrequency: "one time", isLifetime: true)
    ]), onPurchase: { _ in

    })
}
